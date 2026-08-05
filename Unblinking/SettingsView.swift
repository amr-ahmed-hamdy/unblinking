import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var coordinator: WakeCoordinator

    var body: some View {
        TabView {
            GeneralTab(preferences: preferences, coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gearshape") }

            SleepTab(preferences: preferences)
                .tabItem { Label("Sleep", systemImage: "moon.zzz") }

            ClosedLidTab(preferences: preferences, coordinator: coordinator)
                .tabItem { Label("Closed Lid", systemImage: "laptopcomputer") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)
    }

    /// All tabs share one height, so this is sized to the tallest (Closed Lid) with a
    /// little slack, tall enough that its buttons are not cut off, short enough that the
    /// lighter tabs don't sit in a sea of empty space.
    static let windowSize = CGSize(width: 500, height: 505)
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var coordinator: WakeCoordinator
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var needsApproval = LoginItem.requiresApproval

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                            loginItemError = nil
                            needsApproval = LoginItem.requiresApproval
                        } catch {
                            loginItemError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }

                if needsApproval {
                    HStack(spacing: 8) {
                        Text("macOS needs you to approve this.")
                            .foregroundColor(.secondary)
                        Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                    }
                    .font(.callout)
                }

                if let loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundColor(.red)
                }
            }

            Divider().padding(.vertical, 4)

            Section {
                // Routed through the coordinator so changing this while a session is
                // running re-times it, matching what the menu's "Turn On For" does.
                // Binding straight to preferences left a running session on its old
                // duration with no visible effect.
                Picker("Duration", selection: Binding(
                    get: { preferences.defaultDuration },
                    set: { coordinator.setDuration($0) }
                )) {
                    ForEach(SessionDuration.presets, id: \.self) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                Text("Applies to the session running now, and to the next one you start.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                Toggle("Restore last state at launch", isOn: $preferences.restoreStateAtLaunch)
                Text("If Unblinking was on when it last quit, it turns itself back on.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 4)

            Section {
                Picker("Menu bar icon", selection: $preferences.iconStyle) {
                    ForEach(IconStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Text(preferences.iconStyle.explanation)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show time in the menu bar", isOn: $preferences.showTimeInMenuBar)
                if preferences.showTimeInMenuBar {
                    Picker("Time", selection: $preferences.timeDisplay) {
                        ForEach(TimeDisplay.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // Without this, Form centres its rows vertically and leaves a band of dead
            // space above and below the controls.
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

// MARK: - Sleep

private struct SleepTab: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Text("What Unblinking should prevent while it's on:")
                .font(.callout)
                .foregroundColor(.secondary)

            Toggle("Display sleep", isOn: $preferences.preventDisplaySleep)
            caption("Keeps the screen lit.", flag: "caffeinate -d")

            Toggle("Idle system sleep", isOn: $preferences.preventIdleSleep)
            caption("Stops the Mac sleeping while you are away from it.",
                    flag: "caffeinate -i")

            Toggle("Disk sleep", isOn: $preferences.preventDiskSleep)
            caption("Keeps drives spun up.", flag: "caffeinate -m")

            Toggle("System sleep while plugged in", isOn: $preferences.preventSystemSleepOnAC)
            caption("Has no effect on battery.", flag: "caffeinate -s")

            Divider().padding(.vertical, 6)

            Text("None of these affect what happens when you close the lid. That needs "
                 + "closed-lid mode, on the Closed Lid tab.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    /// Plain-English description plus the flag it maps to, set in monospace so the flag
    /// reads as a command rather than as the last two words of the sentence.
    private func caption(_ description: String, flag: String) -> some View {
        (
            Text(description + " ")
                + Text(flag).font(.system(.caption, design: .monospaced))
        )
        .font(.caption)
        .foregroundColor(.secondary)
    }
}

// MARK: - Closed lid

private struct ClosedLidTab: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var coordinator: WakeCoordinator
    @State private var showingRuleText = false

    /// nil until the first poll lands. Never read synchronously from `body`, see
    /// `PowerEnvironment.lidCloseWouldSleepAsync`.
    @State private var lidWouldSleep: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Keep this Mac awake with the lid closed",
                       isOn: Binding(
                        get: { preferences.closedLidEnabled },
                        set: { coordinator.setClosedLidEnabled($0) }
                       ))
                    .font(.headline)

                Text("caffeinate alone can't do this. Closing the lid triggers clamshell "
                     + "sleep, which power assertions don't affect. Unblinking turns off the "
                     + "system-wide sleep switch instead, which needs administrator access "
                     + "once.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                statusBox

                Divider()

                Text("On battery").font(.headline)

                // Routed through the coordinator rather than bound straight to
                // preferences, so a policy change is applied immediately instead of
                // waiting for the next power-source event.
                Picker("", selection: Binding(
                    get: { preferences.batteryPolicy },
                    set: { coordinator.setBatteryPolicy($0) }
                )) {
                    ForEach(BatteryPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if preferences.batteryPolicy == .offBelowThreshold {
                    HStack {
                        Text("Turn off below")
                        Stepper(
                            "\(preferences.batteryThreshold)%",
                            value: Binding(
                                get: { preferences.batteryThreshold },
                                set: { coordinator.setBatteryThreshold($0) }
                            ),
                            in: 5...90,
                            step: 5
                        )
                    }
                }

                Text(preferences.batteryPolicy.explanation)
                    .font(.callout)
                    .foregroundColor(preferences.batteryPolicy == .never ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Permission").font(.headline)

                HStack {
                    Text(coordinator.isClosedLidAuthorized
                         ? "Granted. Unblinking can turn closed-lid mode on and off without asking again."
                         : "Not granted yet. You'll be asked once when you first turn this on.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }

                HStack {
                    Button("Show What Gets Installed") { showingRuleText.toggle() }
                    if coordinator.isClosedLidAuthorized {
                        Button("Remove Permission") {
                            coordinator.removeClosedLidAuthorization()
                        }
                    }
                }

                if showingRuleText {
                    Text(SudoersRunner.ruleText(user: NSUserName()))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                }
            }
            .padding(20)
        }
        // Polled rather than read on demand, because `SleepDisabled` is a system-wide
        // flag that anything can change: another app, or `sudo pmset` in Terminal. The
        // task is cancelled when the window closes, so nothing runs in the background.
        .task {
            while !Task.isCancelled {
                lidWouldSleep = await PowerEnvironment.lidCloseWouldSleepAsync()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var statusBox: some View {
        Label(
            lidWouldSleep.map {
                $0
                    ? "Right now, closing the lid would put this Mac to sleep."
                    : "Right now, closing the lid would not put this Mac to sleep."
            } ?? "Checking what closing the lid would do…",
            systemImage: lidWouldSleep.map { $0 ? "moon.fill" : "sun.max.fill" }
                ?? "ellipsis.circle"
        )
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Text(AppInfo.name).font(.title2).bold()
            Text(AppInfo.versionString)
                .font(.callout)
                .foregroundColor(.secondary)

            Text(AppInfo.tagline)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            Divider().padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Label("Click the eye to turn Unblinking on or off", systemImage: "cursorarrow.click")
                Label("Right-click for duration and settings", systemImage: "cursorarrow.click.2")
                Label("A glowing eye means it's on", systemImage: "eye")
            }
            .font(.callout)

            Divider().padding(.vertical, 4)

            VStack(spacing: 6) {
                Text("Made by \(AppInfo.author)")
                    .font(.callout)

                HStack(spacing: 14) {
                    Link("LinkedIn", destination: AppInfo.linkedIn)
                    Link("GitHub", destination: AppInfo.repository)
                }
                .font(.callout)

                Text(AppInfo.copyright)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(20)
    }
}
