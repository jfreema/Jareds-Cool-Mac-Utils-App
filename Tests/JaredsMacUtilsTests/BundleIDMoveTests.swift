import Foundation
import Testing
@testable import JaredsMacUtils

/// An old and a new settings domain of its own for each test, removed after
private func withDomains(_ body: (_ old: String, _ new: String) -> Void) {
    let id = UUID().uuidString
    let old = "jaredsmacutils-test-old-\(id)"
    let new = "jaredsmacutils-test-new-\(id)"
    defer { for domain in [old, new] { UserDefaults.standard.removePersistentDomain(forName: domain) } }
    body(old, new)
}

private func settings(_ domain: String) -> [String: Any] {
    UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
}

struct BundleIDMoveTests {
    @Test func takesTheOldSettingsOnce() {
        withDomains { old, new in
            UserDefaults.standard.setPersistentDomain(["snapWindows": true, "snapThirds": false,
                                                       "NSStatusItem Preferred Position Item-0": 412.5],
                                                      forName: old)
            #expect(BundleIDMove.carryOverSettings(from: old, to: new))
            #expect(settings(new)["snapWindows"] as? Bool == true)
            #expect(settings(new)["snapThirds"] as? Bool == false)
            #expect(settings(new)["NSStatusItem Preferred Position Item-0"] as? Double == 412.5)
            #expect(settings(old).isEmpty)
            // The next launch has nothing to take
            #expect(!BundleIDMove.carryOverSettings(from: old, to: new))
            #expect(settings(new)["snapWindows"] as? Bool == true)
        }
    }

    @Test func keepsWhatTheNewBundleIDHasAlready() {
        withDomains { old, new in
            UserDefaults.standard.setPersistentDomain(["snipScreen": false, "recordGIFs": true], forName: old)
            UserDefaults.standard.setPersistentDomain(["snipScreen": true], forName: new)
            #expect(BundleIDMove.carryOverSettings(from: old, to: new))
            #expect(settings(new)["snipScreen"] as? Bool == true)
            #expect(settings(new)["recordGIFs"] as? Bool == true)
        }
    }

    @Test func aFreshInstallHasNothingToTake() {
        withDomains { old, new in
            #expect(!BundleIDMove.carryOverSettings(from: old, to: new))
            #expect(settings(new).isEmpty)
        }
    }
}
