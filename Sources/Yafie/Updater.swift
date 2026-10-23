import AppKit
import CryptoKit
import Security
import ServiceManagement

/// Updates from the repo's downloads folder
@MainActor
final class Updater {
    private(set) var isBusy = false

    private static let repo = "jfreema/Jareds-Cool-Mac-Utils-App"
    private static let reopensAtLogin = "reopensAtLogin"

    /// What build.sh --pkg publishes next to the installer
    struct Release: Decodable, Sendable {
        let version: String
        let url: URL
        let sha256: String
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Copies before 1.1.3 read downloads/latest.json, and only take an app named Yafie.app. Once the app is renamed,
    /// that feed stays at the last Yafie, so they come through an updater that can take the new name.
    private static var feed: URL {
        // Overridable for testing
        if let custom = UserDefaults.standard.string(forKey: "updateFeed"), let url = URL(string: custom) { return url }
        return URL(string: "https://raw.githubusercontent.com/\(repo)/main/downloads/update.json")!
    }

    /// Replaced on disk since launch
    static var isStale: Bool {
        let info = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
        guard let onDisk = info?["CFBundleShortVersionString"] as? String else { return false }
        return onDisk != Bundle.main.shortVersion
    }

    func checkForUpdates(askFirst: Bool = true) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await check(askFirst: askFirst)
            isBusy = false
        }
    }

    private func check(askFirst: Bool) async {
        let current = Bundle.main.shortVersion
        let release: Release
        do {
            release = try await Self.latestRelease(from: Self.feed)
        } catch {
            logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            Alert.show("Couldn't check for updates", error.localizedDescription)
            return
        }
        guard release.version.compare(current, options: .numeric) == .orderedDescending else {
            Alert.show("\(Yafie.name) is up to date", "Version \(current) is the newest.")
            return
        }
        if askFirst {
            guard Alert.confirm("\(Yafie.name) \(release.version) is available",
                                "You have \(current). \(Yafie.name) restarts on the new version when it's done.",
                                button: "Update") else { return }
        }
        let app = Bundle.main.bundleURL
        let installed: URL
        do {
            // Translocated copies run from a read-only folder
            guard !app.path.contains("/AppTranslocation/") else {
                throw Failure("Move \(Yafie.name) to your Applications folder, open it from there, then try again.")
            }
            guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
                throw Failure("\(Yafie.name) can't replace itself in \(app.deletingLastPathComponent().path). "
                              + "Download the new version from GitHub instead.")
            }
            installed = try await Self.replace(app, with: release, bundleID: Bundle.main.bundleIdentifier)
        } catch {
            logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
            Alert.show("Couldn't update \(Yafie.name)", error.localizedDescription)
            return
        }
        logger.notice(
            "Updated to \(release.version, privacy: .public) at \(installed.path, privacy: .public), restarting")
        Self.relaunch(installed)
    }

    nonisolated private static func latestRelease(from feed: URL) async throws -> Release {
        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response)
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw Failure("The update information didn't make sense.")
        }
        return release
    }

    /// Download, verify, swap in. The new version keeps the name it has in the installer: under a new name, it goes in
    /// beside the old copy, which is then removed. Returns where it ended up.
    nonisolated static func replace(_ app: URL, with release: Release, bundleID: String?) async throws -> URL {
        let files = FileManager.default
        // Same volume as the app, so the swap is atomic
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? files.removeItem(at: work) }

        let (download, response) = try await URLSession.shared.download(from: release.url)
        let pkg = work.appendingPathComponent("Yafie.pkg")
        try files.moveItem(at: download, to: pkg)
        try checkStatus(response)
        let digest = SHA256.hash(data: try Data(contentsOf: pkg)).map { String(format: "%02x", $0) }.joined()
        // Caches can serve the new version file before the new package
        guard digest == release.sha256.lowercased() else {
            throw Failure("The download didn't match the published version. Try again in a few minutes.")
        }

        // Unpack it instead of running Installer, which would want a password
        let expanded = work.appendingPathComponent("expanded")
        guard Shell.run("/usr/sbin/pkgutil", ["--expand-full", pkg.path, expanded.path], timeout: 60).status == 0,
              let unpacked = findApp(in: expanded, bundleID: bundleID) else {
            throw Failure("Couldn't unpack the downloaded installer.")
        }
        let staged = work.appendingPathComponent(unpacked.lastPathComponent)
        try files.moveItem(at: unpacked, to: staged)

        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == release.version,
              Shell.run("/usr/bin/codesign", ["--verify", "--strict", staged.path]).status == 0 else {
            throw Failure("The downloaded app didn't check out.")
        }
        // Once signed by a Developer ID, only take updates signed by the same team
        if let ours = team(of: app), team(of: staged) != ours {
            throw Failure("The download isn't signed by the same developer as this copy of \(Yafie.name).")
        }
        // Same name, as macOS compares names, ignoring case
        guard staged.lastPathComponent.lowercased() != app.lastPathComponent.lowercased() else {
            _ = try files.replaceItemAt(app, withItemAt: staged)
            return app
        }
        let renamed = app.deletingLastPathComponent()
            .appendingPathComponent(staged.lastPathComponent, isDirectory: true)
        if files.fileExists(atPath: renamed.path) {
            // An earlier copy of the new version, say from its installer, but never someone else's app
            guard identifier(of: renamed) == bundleID else {
                throw Failure("Another app is already at \(renamed.path).")
            }
            _ = try files.replaceItemAt(renamed, withItemAt: staged)
        } else {
            try files.moveItem(at: staged, to: renamed)
        }
        do {
            try files.removeItem(at: app)
        } catch {
            logger.error("Couldn't remove the old copy: \(error.localizedDescription, privacy: .public)")
        }
        return renamed
    }

    /// Lands in <name>.pkg/Payload, and macOS counts .pkg folders as bundles too. Found by bundle ID, since the
    /// name can change.
    nonisolated private static func findApp(in folder: URL, bundleID: String?) -> URL? {
        guard let bundleID,
              let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walk where url.pathExtension == "app" {
            if identifier(of: url) == bundleID { return url }
            walk.skipDescendants()
        }
        return nil
    }

    /// The Apple Developer team that signed it, or nil for a self-signed or ad hoc signature
    nonisolated static func team(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    nonisolated private static func identifier(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String
    }

    nonisolated private static func checkStatus(_ response: URLResponse) throws {
        // file: URLs have no status
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure("GitHub answered with error \(http.statusCode).")
        }
    }

    /// Reopens once this process exits, from where the app is now
    static func relaunch(_ app: URL = Bundle.main.bundleURL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                             app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// At launch. Open at Login follows the app by its bundle ID: macOS moves it to wherever the app is the first time
    /// the app asks about it, so after a move to a new name it asks right away. 1.1.3, which made that move, could
    /// instead turn it off on the way out, leaving a note to turn it back on here.
    static func keepOpenAtLogin() {
        guard UserDefaults.standard.bool(forKey: reopensAtLogin) else {
            _ = SMAppService.mainApp.status
            return
        }
        UserDefaults.standard.removeObject(forKey: reopensAtLogin)
        do {
            try SMAppService.mainApp.register()
            logger.notice("Turned Open at Login back on after the move")
        } catch {
            logger.error("Couldn't turn Open at Login back on: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
}
