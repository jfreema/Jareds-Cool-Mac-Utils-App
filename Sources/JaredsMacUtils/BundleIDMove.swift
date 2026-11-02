import AppKit

/// The move from the app's first bundle ID (JaredsMacApp.oldBundleID) to one that matches its name. macOS keeps
/// settings, permissions and Open at Login by bundle ID. The settings come across here, Open at Login comes back from
/// the note the old copy left (Updater.keepOpenAtLogin), and the switches that need a permission ask for it again
/// (AppDelegate.askForPermissionsAgain).
enum BundleIDMove {
    /// Takes the settings the old bundle ID left, before anything reads one, keeping any the new one has already. True
    /// if there were some, which makes this the first launch since the move. Once taken, they're gone from the old one.
    static func carryOverSettings(from old: String = JaredsMacApp.oldBundleID,
                                  to new: String = JaredsMacApp.bundleID) -> Bool {
        let defaults = UserDefaults.standard
        guard let settings = defaults.persistentDomain(forName: old), !settings.isEmpty else { return false }
        let kept = defaults.persistentDomain(forName: new) ?? [:]
        defaults.setPersistentDomain(settings.merging(kept) { _, mine in mine }, forName: new)
        defaults.removePersistentDomain(forName: old)
        return true
    }

    /// What's left under the old bundle ID: older copies beside this one, its switches in Privacy & Security, which
    /// would sit beside the new ones doing nothing, and its caches
    @MainActor
    static func forgetOldBundleID() {
        let old = JaredsMacApp.oldBundleID
        // A copy from before the app's last rename would open at login too, and two copies fight over sleep. By what
        // its Info.plist says, since LaunchServices can still have this copy under the old bundle ID.
        let folder = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        for app in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: old)
        where app.deletingLastPathComponent().standardizedFileURL == folder {
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == old else { continue }
            do {
                try FileManager.default.removeItem(at: app)
                logger.notice("Removed an older copy at \(app.path, privacy: .public)")
            } catch {
                logger.error("Couldn't remove an older copy: \(error.localizedDescription, privacy: .public)")
            }
        }
        // tccutil can take a moment
        DispatchQueue.global(qos: .utility).async {
            let reset = Shell.run("/usr/bin/tccutil", ["reset", "All", old])
            if reset.status == 0 {
                logger.notice("Reset the old bundle ID's permissions")
            } else {
                logger.error("Couldn't reset the old bundle ID's permissions: \(reset.output, privacy: .public)")
            }
            let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
            for leftover in ["Caches/\(old)", "HTTPStorages/\(old)", "HTTPStorages/\(old).binarycookies",
                             "Saved Application State/\(old).savedState"] {
                try? FileManager.default.removeItem(at: library.appendingPathComponent(leftover))
            }
        }
    }
}
