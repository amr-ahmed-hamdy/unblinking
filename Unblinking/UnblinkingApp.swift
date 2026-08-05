import AppKit

@main
enum UnblinkingApp {
    /// NSApplication holds its delegate weakly.
    private static var delegate: AppDelegate?

    static func main() {
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        delegate = appDelegate
        application.delegate = appDelegate
        // Menu bar only, no Dock icon, no app switcher entry.
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: WakeCoordinator?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var signalSources: [DispatchSourceSignal] = []

    /// The unit test bundle launches the host app. Building a status item during tests
    /// would add a stray eye to the real menu bar, so skip all UI in that case.
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }

        let coordinator = WakeCoordinator()
        let settingsWindow = SettingsWindowController(coordinator: coordinator)
        let statusItem = StatusItemController(coordinator: coordinator)
        statusItem.onOpenSettings = { [weak settingsWindow] in settingsWindow?.show() }

        self.coordinator = coordinator
        self.settingsWindow = settingsWindow
        self.statusItem = statusItem

        installTerminationHandlers()
        coordinator.bootstrap()
        statusItem.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.prepareForTermination()
    }

    /// `applicationWillTerminate` covers Quit and logout, but not a `kill`. These signal
    /// sources catch SIGTERM/SIGINT so the system-wide sleep flag still gets cleared.
    ///
    /// Nothing catches SIGKILL, that path is handled by the recovery check at next launch.
    private func installTerminationHandlers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(systemWillPowerOff),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )

        for rawSignal in [SIGTERM, SIGINT] {
            // Ignore the default disposition so the dispatch source gets the signal.
            signal(rawSignal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: rawSignal, queue: .main)
            source.setEventHandler { [weak self] in
                self?.coordinator?.prepareForTermination()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    @objc private func systemWillPowerOff() {
        coordinator?.prepareForTermination()
    }
}
