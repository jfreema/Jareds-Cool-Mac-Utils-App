import AppKit
import Carbon.HIToolbox

/// control+option+L locks the screen, as Lock Screen in the Apple menu does, so you can walk away while the Mac stays
/// awake
@MainActor
final class ScreenLock {
    private typealias LockScreenImmediate = @convention(c) () -> Int32

    /// Lock Screen's own call, private to macOS, which Hammerspoon and other utilities have used for years
    private static let lockScreenImmediate: LockScreenImmediate? = {
        guard let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/A/login", RTLD_LAZY),
              let symbol = dlsym(login, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockScreenImmediate.self)
    }()

    private var hotKey: HotKey?

    /// Takes the shortcut, unless it's taken already
    func refresh() {
        guard hotKey == nil else { return }
        hotKey = HotKeys.register(kVK_ANSI_L, controlKey | optionKey) { Self.lock() }
        if hotKey == nil { logger.error("Another app is using control+option+L") }
    }

    static func lock() {
        logger.notice("Locking the screen")
        if let lockScreenImmediate {
            _ = lockScreenImmediate()
        } else {
            // Without the private call, the display sleeps, which locks the Mac unless its password waits
            DispatchQueue.global().async { _ = Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
        }
    }
}
