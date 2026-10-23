import CryptoKit
import Foundation
import Testing
@testable import Yafie

private let ourID = "io.github.jfreema.yafie"

/// An Applications folder and a Downloads folder of its own for each test, removed after
private func withFolders(_ body: (_ applications: URL, _ downloads: URL) async throws -> Void) async throws {
    let files = FileManager.default
    let folders = ["Applications", "Downloads"].map {
        files.temporaryDirectory.appendingPathComponent("UpdaterTests-\(UUID().uuidString)/\($0)")
    }
    defer { for folder in folders { try? files.removeItem(at: folder.deletingLastPathComponent()) } }
    for folder in folders { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
    try await body(folders[0], folders[1])
}

/// A stand-in app, signed ad hoc, with /usr/bin/true for its executable
@discardableResult
private func makeApp(_ name: String, version: String, id: String = ourID, in folder: URL) throws -> URL {
    let app = folder.appendingPathComponent(name)
    let executable = app.appendingPathComponent("Contents/MacOS/app")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                              "CFBundleExecutable": "app", "CFBundlePackageType": "APPL"]
    try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
    #expect(Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]).status == 0)
    return app
}

/// An installer holding one app, as build.sh makes, and the release that offers it
private func makeRelease(_ name: String, version: String, id: String = ourID,
                         in folder: URL) throws -> Updater.Release {
    let root = folder.appendingPathComponent("root-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try makeApp(name, version: version, id: id, in: root)
    let pkg = folder.appendingPathComponent("\(UUID().uuidString).pkg")
    let built = Shell.run("/usr/bin/pkgbuild", ["--root", root.path, "--identifier", id, "--version", version,
                                                "--install-location", "/Applications", pkg.path])
    #expect(built.status == 0)
    let digest = SHA256.hash(data: try Data(contentsOf: pkg)).map { String(format: "%02x", $0) }.joined()
    return Updater.Release(version: version, url: pkg, sha256: digest)
}

private func version(of app: URL) -> String? {
    let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
    return info?["CFBundleShortVersionString"] as? String
}

private func contents(of folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

struct UpdaterTests {
    @Test func aNewVersionReplacesTheAppInPlace() async throws {
        try await withFolders { applications, downloads in
            let app = try makeApp("Yafie.app", version: "1.0", in: applications)
            let release = try makeRelease("Yafie.app", version: "2.0", in: downloads)

            let installed = try await Updater.replace(app, with: release, bundleID: ourID)

            #expect(installed.path == app.path)
            #expect(version(of: app) == "2.0")
            #expect(try contents(of: applications) == ["Yafie.app"])
        }
    }

    @Test func aRenamedVersionGoesInBesideAndTheOldOneGoes() async throws {
        try await withFolders { applications, downloads in
            let app = try makeApp("Yafie.app", version: "1.0", in: applications)
            let release = try makeRelease("jaredsmacutils.app", version: "2.0", in: downloads)

            let installed = try await Updater.replace(app, with: release, bundleID: ourID)

            #expect(installed.path == applications.appendingPathComponent("jaredsmacutils.app").path)
            #expect(version(of: installed) == "2.0")
            #expect(try contents(of: applications) == ["jaredsmacutils.app"])
        }
    }

    @Test func aRenamedVersionReplacesAnEarlierCopyOfItself() async throws {
        try await withFolders { applications, downloads in
            let app = try makeApp("Yafie.app", version: "1.0", in: applications)
            try makeApp("jaredsmacutils.app", version: "1.5", in: applications)
            let release = try makeRelease("jaredsmacutils.app", version: "2.0", in: downloads)

            let installed = try await Updater.replace(app, with: release, bundleID: ourID)

            #expect(version(of: installed) == "2.0")
            #expect(try contents(of: applications) == ["jaredsmacutils.app"])
        }
    }

    @Test func neverReplacesSomeoneElsesAppWithTheNewName() async throws {
        try await withFolders { applications, downloads in
            let app = try makeApp("Yafie.app", version: "1.0", in: applications)
            let theirs = try makeApp("jaredsmacutils.app", version: "9.0", id: "someone.else", in: applications)
            let release = try makeRelease("jaredsmacutils.app", version: "2.0", in: downloads)

            await #expect(throws: Updater.Failure.self) {
                try await Updater.replace(app, with: release, bundleID: ourID)
            }

            #expect(version(of: app) == "1.0")
            #expect(version(of: theirs) == "9.0")
        }
    }

    @Test func ignoresAnInstallerWithoutOurApp() async throws {
        try await withFolders { applications, downloads in
            let app = try makeApp("Yafie.app", version: "1.0", in: applications)
            let release = try makeRelease("Yafie.app", version: "2.0", id: "someone.else", in: downloads)

            await #expect(throws: Updater.Failure.self) {
                try await Updater.replace(app, with: release, bundleID: ourID)
            }

            #expect(version(of: app) == "1.0")
            #expect(try contents(of: applications) == ["Yafie.app"])
        }
    }

    @Test func rejectsADownloadThatDoesNotMatchItsHash() async throws {
        try await withFolders { applications, downloads in
            let app = try makeApp("Yafie.app", version: "1.0", in: applications)
            let release = try makeRelease("jaredsmacutils.app", version: "2.0", in: downloads)
            let tampered = Updater.Release(version: release.version, url: release.url,
                                           sha256: String(repeating: "0", count: 64))

            await #expect(throws: Updater.Failure.self) {
                try await Updater.replace(app, with: tampered, bundleID: ourID)
            }

            #expect(try contents(of: applications) == ["Yafie.app"])
        }
    }
}
