import AppKit
import SwiftUI

/// Hosts the settings UI in a hand-built window.
///
/// Deliberately not SwiftUI's `Settings` scene: opening that from an accessory
/// (`LSUIElement`) app relies on the `showSettingsWindow:` selector, whose name and
/// availability have shifted between macOS releases. A plain `NSWindow` always works.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let coordinator: WakeCoordinator
    private let preferences: Preferences

    init(coordinator: WakeCoordinator, preferences: Preferences = .shared) {
        self.coordinator = coordinator
        self.preferences = preferences
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(
                rootView: SettingsView(preferences: preferences, coordinator: coordinator)
            )

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: SettingsView.windowSize),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Unblinking Settings"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }

        // An accessory app has no Dock icon, so it has to ask for focus explicitly or the
        // window opens behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
