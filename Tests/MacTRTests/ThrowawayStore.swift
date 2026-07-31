// ThrowawayStore.swift — a defaults suite that tests can dirty freely.

import Foundation

/// Runs `body` against a private, empty UserDefaults suite and removes it
/// afterwards, so tests never read or clobber the real user settings.
func withThrowawayStore(_ body: (UserDefaults) throws -> Void) throws {
    let name = "com.m1ngli.MacTRAI.tests.\(UUID().uuidString)"
    guard let store = UserDefaults(suiteName: name) else {
        fatalError("could not open a throwaway defaults suite")
    }
    defer { store.removePersistentDomain(forName: name) }
    try body(store)
}
