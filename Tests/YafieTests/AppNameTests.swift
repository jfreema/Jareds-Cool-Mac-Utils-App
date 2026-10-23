import Foundation
import Testing
@testable import Yafie

/// A file in the repo's Resources folder, as a dictionary
private func resource(_ path: String) -> [String: Any] {
    let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources")
    return NSDictionary(contentsOf: resources.appendingPathComponent(path)) as? [String: Any] ?? [:]
}

struct AppNameTests {
    @Test func finderShowsTheFullName() {
        let info = resource("Info.plist")
        let localized = resource("en.lproj/InfoPlist.strings")
        // Finder only uses the localized name while the plain one matches the file name, which build.sh takes from
        // CFBundleExecutable
        #expect(info["CFBundleDisplayName"] as? String == info["CFBundleExecutable"] as? String)
        #expect(info["LSHasLocalizedDisplayName"] as? Bool == true)
        #expect(localized["CFBundleDisplayName"] as? String == Yafie.fullName)
    }

    @Test func menusUseTheShortName() {
        #expect(resource("Info.plist")["CFBundleName"] as? String == Yafie.name)
        #expect(resource("en.lproj/InfoPlist.strings")["CFBundleName"] as? String == Yafie.name)
        #expect(Yafie.name.count < 16)
    }

    @Test func keepsTheBundleIDThatPermissionsAndSettingsDependOn() {
        #expect(resource("Info.plist")["CFBundleIdentifier"] as? String == "io.github.jfreema.yafie")
    }
}
