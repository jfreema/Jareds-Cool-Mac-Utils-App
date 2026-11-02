import IOKit
import IOKit.pwr_mgt

/// IOPMrootDomain state and sleep
enum PowerManager {
    /// nil without a lid
    static var isLidClosed: Bool? { flag(kAppleClamshellStateKey) }

    /// False in clamshell mode
    static var lidClosingCausesSleep: Bool? { flag(kAppleClamshellCausesSleepKey) }

    /// Kernel's copy, can lag
    static var isSleepDisabled: Bool? { flag("SleepDisabled") }

    /// False if refused
    static func sleepNow() -> Bool {
        let connection = IOPMFindPowerManagement(kIOMainPortDefault)
        guard connection != 0 else { return false }
        defer { IOServiceClose(connection) }
        return IOPMSleepSystem(connection) == kIOReturnSuccess
    }

    private static func flag(_ key: String) -> Bool? {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return nil }
        defer { IOObjectRelease(rootDomain) }
        return IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
}

/// The lid opening or closing, or an external display changing whether closing it sleeps the Mac
@MainActor
final class LidMonitor {
    /// kIOPMMessageClamshellStateChange, a macro Swift can't import
    nonisolated private static let clamshellChange: UInt32 = 0xE003_4100
    private let onChange: @MainActor () -> Void
    private var notification: io_object_t = 0

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return }
        defer { IOObjectRelease(rootDomain) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(),
                           .commonModes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { context, _, message, _ in
            guard let context, message == LidMonitor.clamshellChange else { return }
            let monitor = Unmanaged<LidMonitor>.fromOpaque(context).takeUnretainedValue()
            // Fires on main run loop
            MainActor.assumeIsolated { monitor.onChange() }
        }, context, &notification)
        if result != KERN_SUCCESS { logger.error("Couldn't watch the lid: \(result)") }
    }
}
