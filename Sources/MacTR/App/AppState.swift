// AppState.swift — the state the UI binds to
//
// Owns the settings and the connection status, and holds the DisplayEngine that
// does the USB work off the main thread (see DisplayEngine.swift for why that
// separation matters). Everything here is @MainActor.

import AppKit
import Foundation
import Observation

// MARK: - Display Set

extension Notification.Name {
    static let deviceStateChanged = Notification.Name("deviceStateChanged")
}

enum DisplaySet: String, CaseIterable, Identifiable, Sendable {
    case systemMonitor = "System Monitor"

    var id: String { rawValue }
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {

    // Connection (UI-facing)
    var isConnected = false
    /// A connect attempt is in flight. Starts true because `start()` kicks one
    /// off immediately: anything that treats "not connected" as "no panel" would
    /// otherwise reach that conclusion before the first attempt has answered.
    var isConnecting = true
    var deviceInfo: DeviceInfo?
    var statusMessage = "Disconnected"

    // Display — everything but currentSet comes from Preferences (see init)
    // rather than carrying inline defaults, so there's only one place that says
    // what a fresh install looks like: DisplaySettings.default.
    var currentSet: DisplaySet = .systemMonitor
    var brightness: Int
    var refreshInterval: Double
    var rotateDisplay: Bool
    var night: NightSchedule

    // Metrics (for menu bar display)
    var frameCount = 0
    var lastFrameSize = 0

    // MARK: - Internal

    private var engine: DisplayEngine?
    private let preferences: Preferences

    // MARK: - Init

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        let saved = preferences.load()
        self.rotateDisplay = saved.rotateDisplay
        self.brightness = saved.brightness
        self.refreshInterval = saved.refreshInterval
        self.night = saved.night
    }

    /// The persisted settings as they currently stand in memory.
    private var displaySettings: DisplaySettings {
        DisplaySettings(
            rotateDisplay: rotateDisplay,
            brightness: brightness,
            refreshInterval: refreshInterval,
            night: night)
    }

    // MARK: - Lifecycle

    func start() {
        let eng = DisplayEngine { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                let prev = self.isConnected
                self.isConnected = status.connected
                self.isConnecting = status.connecting
                self.deviceInfo = status.deviceInfo ?? self.deviceInfo
                self.statusMessage = status.message
                self.frameCount = status.frameCount
                self.lastFrameSize = status.lastFrameSize

                // Log state changes + post notification for UI refresh
                if status.connected != prev {
                    log("[*] LCD \(status.connected ? "connected" : "disconnected")")
                    NotificationCenter.default.post(name: .deviceStateChanged, object: nil)
                }
            }
        }
        engine = eng
        eng.start(set: currentSet, settings: displaySettings)
    }

    func stop() {
        engine?.stop()
        engine = nil
        isConnected = false
        // Also clear this: dropping the engine means no further status will ever
        // arrive, so whatever it holds now it holds forever. Left true, anything
        // waiting on "the attempt settled" would wait for the life of the process.
        isConnecting = false
        statusMessage = "Stopped"
    }

    func connect() {
        engine?.reconnect()
    }

    /// Called when the user changes any display setting. Every Settings control
    /// routes through here, so this is the one place that needs to persist.
    func applySettings() {
        preferences.save(displaySettings)
        engine?.updateSettings(set: currentSet, settings: displaySettings)
    }

    /// Latest rendered frame for the on-Mac preview window
    func currentFrame() -> CGImage? {
        engine?.currentFrame()
    }
}
