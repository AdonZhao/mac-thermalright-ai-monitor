// SettingsView.swift — Settings window (SwiftUI)
//
// Tabs: General | Display | Device | About

import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalSettings
            }

            Tab("Display", systemImage: "display") {
                displaySettings
            }

            Tab("Device", systemImage: "cable.connector") {
                deviceSettings
            }

            Tab("About", systemImage: "info.circle") {
                aboutView
            }
        }
        .padding(.top, 12)
        .frame(width: 480, height: 460)
    }

    // MARK: - General Tab

    private var generalSettings: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                Text("Requires .app bundle to work (not available in debug builds)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                // Built from Preferences' own list: an option offered here is
                // therefore always one load() will accept back.
                Picker("Interval", selection: $state.refreshInterval) {
                    ForEach(Preferences.refreshIntervalChoices) { choice in
                        Text(choice.label).tag(choice.seconds)
                    }
                }
                .onChange(of: state.refreshInterval) {
                    state.applySettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Display Tab

    private var displaySettings: some View {
        Form {
            Section("Display Set") {
                Picker("Active Set", selection: $state.currentSet) {
                    ForEach(DisplaySet.allCases) { set in
                        Text(set.rawValue).tag(set)
                    }
                }
                .onChange(of: state.currentSet) {
                    state.applySettings()
                }
            }

            Section("Brightness") {
                HStack {
                    Slider(value: brightnessBinding, in: Preferences.brightnessBounds, step: 1) {
                        Text("Level")
                    }
                    Text("\(state.brightness)")
                        .monospacedDigit()
                        .frame(width: 24)
                }
                .onChange(of: state.brightness) {
                    state.applySettings()
                }
                Text("1 = original, 10 = maximum")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rotation") {
                Toggle("Rotate 180°", isOn: $state.rotateDisplay)
                    .onChange(of: state.rotateDisplay) {
                        state.applySettings()
                    }
                Text("Enable if display appears upside down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Night") {
                Toggle("Blank the LCD overnight", isOn: $state.night.enabled)
                    .onChange(of: state.night.enabled) {
                        state.applySettings()
                    }

                DatePicker("From", selection: nightStart, displayedComponents: .hourAndMinute)
                    .disabled(!state.night.enabled)
                DatePicker("Until", selection: nightEnd, displayedComponents: .hourAndMinute)
                    .disabled(!state.night.enabled)

                Text("The dashboard moves to a window on the Mac while the LCD is dark. "
                    + "Setting both times the same leaves it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Device Tab

    private var deviceSettings: some View {
        Form {
            Section("Connection") {
                LabeledContent("Status") {
                    HStack {
                        Circle()
                            .fill(state.isConnected ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.isConnected ? "Connected" : "Disconnected")
                    }
                }

                if let info = state.deviceInfo {
                    LabeledContent("Resolution", value: "\(info.width) × \(info.height)")
                    LabeledContent("PM / SUB / FBL", value: "\(info.pm) / \(info.sub) / \(info.fbl)")
                    LabeledContent("PID", value: String(format: "0x%04X", info.pid))
                }

                if !state.isConnected {
                    Button("Reconnect") {
                        state.connect()
                    }
                }
            }

            Section("Statistics") {
                LabeledContent("Frames Sent", value: "\(state.frameCount)")
                LabeledContent("Last Frame", value: "\(state.lastFrameSize / 1024) KB")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - About Tab

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("MacTR")
                .font(.title)
                .fontWeight(.semibold)

            Text("macOS driver for Thermalright Trofeo Vision 9.16 LCD")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Text("Built with Swift 6.3 + libusb")
                Text("Protocol: LY Bulk (thermalright-trcc-linux)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }

    // MARK: - Helpers

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("[Settings] Launch at login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(state.brightness) },
            set: { state.brightness = Int($0) }
        )
    }

    // DatePicker speaks Date; the schedule stores minutes since midnight, because
    // a window like 18:30→09:00 has to be comparable without dragging a calendar
    // date into it. These bind the two, and save on every edit — the pickers have
    // no discrete "committed" moment to hang an onChange on.
    private var nightStart: Binding<Date> { nightTime(\.startMinute) }
    private var nightEnd: Binding<Date> { nightTime(\.endMinute) }

    private func nightTime(_ minute: WritableKeyPath<NightSchedule, Int>) -> Binding<Date> {
        Binding(
            get: { Self.time(atMinute: state.night[keyPath: minute]) },
            set: {
                state.night[keyPath: minute] = Self.minuteOfDay(of: $0)
                state.applySettings()
            }
        )
    }

    /// Today at `m` minutes past midnight — only the time is ever read back out.
    private static func time(atMinute m: Int) -> Date {
        Calendar.current.date(
            bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }

    private static func minuteOfDay(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
