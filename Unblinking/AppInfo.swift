import Foundation

/// Project and author metadata, kept in one place so the About tab, the README and any
/// future links never drift apart.
enum AppInfo {
    static let name = "Unblinking"
    static let author = "Amr Ahmed Hamdy"
    static let copyright = "© 2026 Amr Ahmed Hamdy · MIT Licensed"

    static let tagline = "A menu bar switch for keeping this Mac awake, including with "
        + "the lid closed, which the caffeinate command can't do on its own."

    // MARK: - Links
    //
    // Change these here and everything that links out follows.

    static let linkedIn = URL(string: "https://www.linkedin.com/in/amr-hamdy/")!
    static let repository = URL(string: "https://github.com/amr-ahmed-hamdy/unblinking")!
    static let issues = URL(string: "https://github.com/amr-ahmed-hamdy/unblinking/issues")!

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var versionString: String { "Version \(version) (\(build))" }
}
