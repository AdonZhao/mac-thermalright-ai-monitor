// DisplayEngine.swift — drives the LCD, entirely off the main thread
//
// Split out of AppState.swift, which had grown to hold five unrelated things.
// USB I/O must never touch the main thread: a blocked main thread shows up as the
// macOS spinner and a frozen keyboard.

import AppKit
import Foundation
import Synchronization

// MARK: - Engine Status

struct EngineStatus: Sendable {
    let connected: Bool
    /// A connect attempt is in flight — neither connected nor known absent yet.
    /// Opening the device and handshaking takes a few seconds, and callers that
    /// treat "not connected" as "no panel" during that window act on a verdict
    /// that hasn't been reached.
    let connecting: Bool
    let deviceInfo: DeviceInfo?
    let message: String
    let frameCount: Int
    let lastFrameSize: Int
}

/// Decides whether a status update is worth posting to the main thread.
/// State transitions (connected/connecting/message) always pass; pure
/// frame-statistics updates — the 15fps "still Active" after every sent
/// frame, only frameCount/lastFrameSize ticking — are limited to 1/s so the
/// frame loop stops scheduling MainActor work per frame.
struct StatusThrottle {
    private var lastState: (connected: Bool, connecting: Bool, message: String)?
    private var lastPostedAt: Double = -.infinity

    mutating func shouldPost(connected: Bool, connecting: Bool, message: String,
                             now: Double) -> Bool {
        let state = (connected, connecting, message)
        let changed = lastState.map { $0 != state } ?? true
        guard changed || now - lastPostedAt >= 1.0 else { return false }
        lastState = state
        lastPostedAt = now
        return true
    }
}

// MARK: - Display Engine (runs entirely off main thread)

final class DisplayEngine: @unchecked Sendable {

    /// Cached all-black JPEG used to blank the LCD during the night window.
    ///
    /// Takes no rotation argument on purpose: an all-black frame turned 180° is
    /// the same frame, so one cached copy serves both orientations. It used to
    /// take a `rotate:` flag that only the first call could influence — the
    /// cache short-circuits every call after it — which is the same species of
    /// lying parameter as the encode flag this file's history is about.
    /// Deadline increment for one frame, nanosecond-precise. Truncating to
    /// whole milliseconds made 1/15s into 66ms — the loop ran at 15.15fps,
    /// ~1% frames nobody asked for.
    static func frameDeadlineStep(_ interval: Double) -> DispatchTimeInterval {
        .nanoseconds(Int(interval * 1_000_000_000))
    }

    nonisolated(unsafe) private static var _blackFrame: Data?
    static func blackFrame() -> Data? {
        if let f = _blackFrame { return f }
        let w = Layout.width, h = Layout.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return nil }
        _blackFrame = JPEGEncoder.encode(img, brightness: 1)
        return _blackFrame
    }

    /// The state more than one thread touches.
    ///
    /// `running` is written from the main actor (`stop()`), from libusb's hotplug
    /// thread (`onDisconnect`), from the sleep/wake handler, and from the render
    /// loop itself — while the loop's `while` condition reads it every frame. As a
    /// plain `var` that was a data race the optimiser is entitled to act on: it
    /// may hoist the load out of the loop, and then `stop()` never lands.
    ///
    /// `settings` and `currentSet` are written from the main actor and read by the
    /// render loop. Tearing there costs at most one frame, but `night` is a
    /// (enabled, start, end) triple with a paired invariant, so a torn read can
    /// produce a window the user never set — say 22:00→09:00 while they were
    /// moving 18:30→09:00 to 22:00→06:00.
    ///
    /// The previous comment here claimed these were "atomically accessed". They
    /// never were; nothing enforced it.
    private struct SharedState {
        var running = false
        var currentSet: DisplaySet = .systemMonitor
        /// Seeded from DisplaySettings.default rather than repeating its values, so
        /// "what does a fresh install look like" has one answer. In practice
        /// start() overwrites this before the render loop reads it.
        var settings = DisplaySettings.default
    }
    private let shared = Mutex(SharedState())

    private let statusCallback: @Sendable (EngineStatus) -> Void
    private let usbQueue = DispatchQueue(label: "com.thermalvision.usb")

    // usbQueue-confined: only the frame loop, connectAndRun and postStatus touch
    // these, and all three run there.
    private var device: USBDevice?
    private var hotplug: USBHotplug?
    private var frameCount = 0
    private var lastFrameSize = 0

    // Renderers
    private let monitorRenderer = MonitorRenderer()

    init(statusCallback: @escaping @Sendable (EngineStatus) -> Void) {
        self.statusCallback = statusCallback
    }

    func start(set: DisplaySet, settings: DisplaySettings) {
        shared.withLock { $0.currentSet = set; $0.settings = settings }

        usbQueue.async { [weak self] in
            guard let self else { return }
            // Start background metrics collection (primes before returning)
            self.monitorRenderer.startMetrics()
            self.setupHotplug()
            self.connectAndRun()
        }
    }

    func stop() {
        shared.withLock { $0.running = false }
        monitorRenderer.stopMetrics()
        usbQueue.async { [weak self] in
            self?.hotplug?.stop()
            self?.hotplug = nil
            self?.device?.close()
            self?.device = nil
        }
    }

    func reconnect() {
        usbQueue.async { [weak self] in
            self?.connectAndRun()
        }
    }

    /// Latest rendered frame for the on-Mac preview window (used while the LCD
    /// is disconnected). Thread-safe: render() serializes internally.
    func currentFrame() -> CGImage? {
        monitorRenderer.render()
    }

    func updateSettings(set: DisplaySet, settings: DisplaySettings) {
        log("[Engine] Settings updated: set=\(set.rawValue), "
            + "brightness=\(settings.brightness), interval=\(settings.refreshInterval), "
            + "rotate=\(settings.rotateDisplay), blanking=\(settings.night.logDescription)")
        shared.withLock { $0.currentSet = set; $0.settings = settings }
    }

    // MARK: - Private (all on usbQueue)

    private func connectAndRun() {
        guard !shared.withLock({ $0.running }) else { return }

        // Ensure metrics collection is running (may have been stopped on disconnect/sleep)
        monitorRenderer.startMetrics()

        // Close existing connection
        device?.close()
        device = nil
        frameCount = 0

        postStatus(connected: false, connecting: true, message: "Connecting...")

        let dev = USBDevice()
        do {
            try dev.open()
        } catch USBError.deviceNotFound {
            postStatus(connected: false, message: "Device not found")
            return
        } catch USBError.deviceBusy {
            postStatus(connected: false, message: "Device busy (Chrome?)")
            return
        } catch {
            postStatus(connected: false, message: "Error: \(error)")
            return
        }

        do {
            let info = try LYProtocol.handshake(device: dev)
            device = dev
            postStatus(connected: true, deviceInfo: info,
                       message: "Connected (\(info.width)x\(info.height))")
            runFrameLoop(device: dev, info: info)
        } catch {
            dev.close()
            postStatus(connected: false, message: "Handshake failed")
        }
    }

    private func runFrameLoop(device: USBDevice, info: DeviceInfo) {
        shared.withLock { $0.running = true }
        // Metrics already collecting in background via startMetrics()

        var nextDeadline = DispatchTime.now()

        // One snapshot per frame, so every decision below is made against a single
        // coherent set of values. Reading the fields one at a time under separate
        // locks would let the schedule change halfway through a frame.
        var frame = shared.withLock { $0 }

        while frame.running {
            let set = frame.currentSet
            let settings = frame.settings

            // Inside the user's night window: blank the LCD; the dashboard shows on
            // the Mac preview instead. Refresh the black frame slowly to save power.
            let night = settings.night.isNight

            // Adaptive frame rate: the device sustains ~19fps, but the dashboard's
            // data only changes every ~2s. Run fast (15fps) ONLY while a column is
            // animating (agent working → breathing, or done → blinking); otherwise
            // idle at the configured interval to save CPU/power on this always-on app.
            let animating = !night && (set == .systemMonitor) && monitorRenderer.wantsHighFrameRate()
            let frameInterval = night ? 3.0 : (animating ? (1.0 / 15.0) : settings.refreshInterval)
            nextDeadline = nextDeadline + DisplayEngine.frameDeadlineStep(frameInterval)

            // autoreleasepool forces CG raster data / CGImage release each frame
            // Without this, Core Graphics caches hundreds of 3.6MB images → GB leak
            autoreleasepool {
                let bright = settings.brightness
                let rotate = settings.rotateDisplay

                let jpeg: Data?

                if night {
                    jpeg = DisplayEngine.blackFrame()
                } else {
                    switch set {
                    case .systemMonitor:
                        if let image = monitorRenderer.render() {
                            jpeg = JPEGEncoder.encode(image, brightness: bright, rotate: rotate)
                        } else {
                            jpeg = nil
                        }
                    }
                }

                if let jpeg {
                    do {
                        try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                        frameCount += 1
                        lastFrameSize = jpeg.count
                        if frameCount == 1 {
                            log("[OK] Active! ~\(jpeg.count / 1024)KB/frame")
                        }
                        postStatus(connected: true, deviceInfo: nil,
                                   message: "Active")
                    } catch {
                        log("[ERROR] Frame send failed: \(error)")
                        shared.withLock { $0.running = false }
                        self.device?.close()
                        self.device = nil

                        // connecting, not merely disconnected: a retry is already
                        // scheduled below. Reporting a bare disconnect here opened the
                        // preview window for the five seconds until the retry landed,
                        // then closed it again — the same flash this engine's status
                        // reporting was changed to avoid at launch.
                        postStatus(connected: false, connecting: true,
                                   message: "Reconnecting...")

                        log("[Engine] Will retry connection in 5s...")
                        Thread.sleep(forTimeInterval: 5)
                        connectAndRun()
                        return
                    }
                }
            }  // autoreleasepool

            // Sleep only the remaining time until next deadline
            // If work took longer than interval, send next frame immediately
            let now = DispatchTime.now()
            if nextDeadline > now {
                Thread.sleep(forTimeInterval: Double(nextDeadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000)
            } else {
                // Work exceeded interval — reset deadline to avoid cascading catch-up
                nextDeadline = now
            }

            // Re-read for the next frame: this is where a settings change or a
            // stop() from another thread becomes visible.
            frame = shared.withLock { $0 }
        }
    }

    private func setupHotplug() {
        let hp = USBHotplug()

        hp.onConnect = { [weak self] in
            guard let self else { return }
            self.usbQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, !self.shared.withLock({ $0.running }) else { return }
                log("[Hotplug] Attempting reconnect...")
                self.monitorRenderer.startMetrics()
                self.connectAndRun()
            }
        }

        hp.onDisconnect = { [weak self] in
            guard let self else { return }
            log("[Hotplug] Device removed")
            self.shared.withLock { $0.running = false }
            // Metrics keep collecting — the on-Mac preview window takes over
            // rendering while the LCD is away
            self.usbQueue.async { [weak self] in
                self?.device?.close()
                self?.device = nil
                self?.postStatus(connected: false, message: "Disconnected (unplugged)")
            }
        }

        hp.start()
        hotplug = hp

        // Watch for macOS wake from sleep — USB needs reconnect after sleep
        // MUST register on main thread for NSWorkspace notifications to fire
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let center = NSWorkspace.shared.notificationCenter

            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                log("[Wake] macOS woke from sleep — reconnecting in 3s...")
                self.usbQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self else { return }
                    self.shared.withLock { $0.running = false }
                    self.device?.close()
                    self.device = nil
                    log("[Wake] Attempting reconnect...")
                    self.connectAndRun()
                }
            }

            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if !self.shared.withLock({ $0.running }) {
                    log("[Wake] Screens woke — reconnecting in 2s...")
                    self.usbQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self, !self.shared.withLock({ $0.running }) else { return }
                        self.connectAndRun()
                    }
                }
            }
        }
    }

    // usbQueue-confined, like the frame loop that drives it
    private var statusThrottle = StatusThrottle()

    private func postStatus(
        connected: Bool, connecting: Bool = false,
        deviceInfo: DeviceInfo? = nil, message: String
    ) {
        guard statusThrottle.shouldPost(connected: connected, connecting: connecting,
                                        message: message,
                                        now: Date().timeIntervalSince1970)
        else { return }
        let status = EngineStatus(
            connected: connected,
            connecting: connecting,
            deviceInfo: deviceInfo,
            message: message,
            frameCount: frameCount,
            lastFrameSize: lastFrameSize)
        statusCallback(status)
    }
}
