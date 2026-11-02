import AppKit

/// The app: its names, and one copy at a time
@main
@MainActor
enum JaredsMacApp {
    /// In menus, alerts and tooltips. CFBundleName too, which stays under 16 characters.
    nonisolated static let name = "Jared's Mac App"
    /// Where there's room, like the About panel. Finder shows it, from en.lproj/InfoPlist.strings.
    nonisolated static let fullName = "Jared's Cool Mac Utilities App"
    /// The bundle ID the app is moving to. A copy with the old one takes an update with this one (Updater.ids).
    nonisolated static let bundleID = "io.github.jfreema.jaredsmacutils"
    /// The bundle ID from the app's first name. macOS keeps permissions, settings and Open at Login by bundle ID.
    nonisolated static let oldBundleID = "io.github.jfreema.yafie"

    static let showMenuNotification = Notification.Name("io.github.jfreema.jaredsmacutils.showMenu")

    static func main() {
        // Watchdog, tuner listener and drum player skip the dupe check
        if CommandLine.arguments.contains(Watchdog.argument) {
            Watchdog.run()
            return
        }
        if CommandLine.arguments.contains(TunerListener.argument) {
            TunerListener.run()
        }
        if CommandLine.arguments.contains(DrumPlayer.argument) {
            DrumPlayer.run()
        }

        // Two copies would fight, even with different bundle IDs
        let me = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier,
           let other = Set([id, bundleID, oldBundleID])
               .flatMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0) })
               .first(where: { $0.processIdentifier != me }) {
            guard replaces(other), quitAndWait(other) else {
                // Else opening it looks like nothing happened
                DistributedNotificationCenter.default().postNotificationName(showMenuNotification, object: nil,
                                                                             userInfo: nil, deliverImmediately: true)
                return
            }
            logger.notice("Took over from the copy that was running")
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// An update installed by hand
    private static func replaces(_ other: NSRunningApplication) -> Bool {
        let mine = Bundle.main.bundleURL.standardizedFileURL
        guard let theirs = other.bundleURL?.standardizedFileURL else { return false }
        // macOS only starts a second copy from the same place if it was replaced on disk
        if theirs == mine { return true }
        let info = NSDictionary(contentsOf: theirs.appendingPathComponent("Contents/Info.plist"))
        guard let version = info?["CFBundleShortVersionString"] as? String else { return false }
        return Bundle.main.shortVersion.compare(version, options: .numeric) == .orderedDescending
    }

    /// Quitting restores sleep first
    private static func quitAndWait(_ other: NSRunningApplication) -> Bool {
        guard other.terminate() else { return false }
        let deadline = Date().addingTimeInterval(10)
        while kill(other.processIdentifier, 0) == 0 {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }
}
