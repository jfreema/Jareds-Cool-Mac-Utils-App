import AppKit
import os

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "lid")

/// No lid sleep, while plugged in or on battery too
@MainActor
final class LidAwakeController {
    enum Status: Equatable {
        case off, waitingForPower, lowBattery, waitingForInternet, active(onBattery: Bool), needsSetup,
             lowPowerNeedsSetup, restoreFailed
    }

    /// On battery, the Mac sleeps as usual from this charge down, in percent
    static let lowBattery = 10

    var onChange: (() -> Void)?

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    /// Only while plugged in, which is how it started out
    private(set) var requiresPower = UserDefaults.standard.object(forKey: Keys.requiresPower) as? Bool ?? true {
        didSet { UserDefaults.standard.set(requiresPower, forKey: Keys.requiresPower) }
    }
    /// Only while online, too
    private(set) var requiresInternet = UserDefaults.standard.bool(forKey: Keys.requiresInternet) {
        didSet { UserDefaults.standard.set(requiresInternet, forKey: Keys.requiresInternet) }
    }
    /// Low Power Mode while it keeps the Mac awake with the lid closed, which starts out on
    private(set) var usesLowPower = UserDefaults.standard.object(forKey: Keys.usesLowPower) as? Bool ?? true {
        didSet { UserDefaults.standard.set(usesLowPower, forKey: Keys.usesLowPower) }
    }
    private var isOnACPower = PowerSource.isOnACPower
    private var batteryLevel = PowerSource.batteryLevel
    private lazy var connectivity = ConnectivityMonitor { [weak self] in self?.changed() }
    /// sudo rule missing or broken
    private var needsSetup = false
    /// Restore failed, user must retry
    private var restoreFailed = false
    /// Flag is ours to undo
    private var ownsSleepDisabled = UserDefaults.standard.bool(forKey: Keys.ownsSleepDisabled) {
        didSet {
            UserDefaults.standard.set(ownsSleepDisabled, forKey: Keys.ownsSleepDisabled)
            watchdog.ownsSleepDisabled = ownsSleepDisabled
        }
    }
    /// Low Power Mode as it was before Yafie turned it on, ours to put back
    private var savedLowPower = LowPowerSetting(UserDefaults.standard.string(forKey: Keys.savedLowPower) ?? "") {
        didSet {
            UserDefaults.standard.set(savedLowPower?.description, forKey: Keys.savedLowPower)
            watchdog.savedLowPower = savedLowPower
        }
    }
    /// The sudoers rule covers Low Power Mode, which rules from before it don't. Nil until checked.
    private var canSetLowPower: Bool?
    /// Done for this lid closing
    private var lowPowerApplied = false
    private var writingLowPower = false
    private let watchdog = Watchdog()
    /// nil if unknown or overridden
    private var lastWritten: Bool?
    /// Sleep Now, until next wake
    private var pausedUntilWake = false
    private var pausedAt = Date.distantPast
    private var writing = false
    private var settingUp = false
    private var terminating = false
    private var systemIsPoweringOff = false
    /// Cancels stale sleep retries
    private var sleepRequestGeneration = 0
    private var started = false
    private var powerMonitor: PowerSourceMonitor?
    private var lidMonitor: LidMonitor?
    private var recheckTimer: Timer?

    private enum Keys {
        static let enabled = "enabled"
        static let requiresPower = "requiresPower"
        static let requiresInternet = "requiresInternet"
        static let ownsSleepDisabled = "ownsSleepDisabled"
        static let usesLowPower = "usesLowPower"
        static let savedLowPower = "savedLowPower"
    }

    var status: Status {
        if restoreFailed { return .restoreFailed }
        guard isEnabled else { return .off }
        if needsSetup { return .needsSetup }
        if lowPowerNeedsSetup { return .lowPowerNeedsSetup }
        if isWaitingForPower { return .waitingForPower }
        if isBatteryLow { return .lowBattery }
        return isOffline ? .waitingForInternet : .active(onBattery: !isOnACPower)
    }

    private var isWaitingForPower: Bool { requiresPower && !isOnACPower }
    private var isBatteryLow: Bool { !isOnACPower && (batteryLevel ?? 100) <= Self.lowBattery }
    private var isOffline: Bool { requiresInternet && !connectivity.isOnline }
    /// A rule from before Low Power Mode, so the menu asks for the password once more
    private var lowPowerNeedsSetup: Bool { usesLowPower && canSetLowPower == false }

    private var wantsSleepDisabled: Bool {
        isEnabled && !isWaitingForPower && !isBatteryLow && !isOffline && !needsSetup && !pausedUntilWake
    }

    /// Only where closing the lid would sleep the Mac without Yafie, so not with an external display in use
    private var wantsLowPower: Bool {
        usesLowPower && wantsSleepDisabled && canSetLowPower != false
            && PowerManager.isLidClosed == true && PowerManager.lidClosingCausesSleep != false
    }

    // MARK: Lifecycle

    func start() {
        started = true
        watchdog.start(ownsSleepDisabled: ownsSleepDisabled, savedLowPower: savedLowPower)
        powerMonitor = PowerSourceMonitor { [weak self] in self?.powerSourceMayHaveChanged() }
        lidMonitor = LidMonitor { [weak self] in self?.changed() }
        let notifications = NSWorkspace.shared.notificationCenter
        _ = notifications.addObserver(forName: NSWorkspace.didWakeNotification,
                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        _ = notifications.addObserver(forName: NSWorkspace.willPowerOffNotification,
                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemIsPoweringOff = true }
        }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck() }
        }
        RunLoop.main.add(timer, forMode: .common)  // fires while menu is open
        recheckTimer = timer
        // Also cleans up after crashes
        changed()
        // Rules from before Low Power Mode don't cover it
        if FileManager.default.fileExists(atPath: SleepSetting.rulePath) {
            Task {
                await checkLowPower()
                changed()
            }
        }
    }

    /// Synchronous, the app is exiting
    func stop() {
        terminating = true
        guard started else { return }
        // First, since putting sleep back can sleep the Mac
        if let savedLowPower, LowPowerSetting.applySynchronously(savedLowPower) {
            self.savedLowPower = nil
            logger.notice("Put Low Power Mode back before quitting")
        }
        guard ownsSleepDisabled else { return }
        sleepRequestGeneration += 1
        if SleepSetting.setSynchronously(disabled: false) {
            ownsSleepDisabled = false
            logger.notice("Turned sleep back on before quitting")
        } else {
            restoreWithPassword()
        }
    }

    // MARK: Menu actions

    func setEnabled(_ enabled: Bool) {
        if enabled {
            Task { await setUpThenEnable() }
        } else {
            isEnabled = false
            needsSetup = false
            changed()
        }
    }

    func finishSetup() {
        Task { await setUpThenEnable() }
    }

    func retryRestore() {
        restoreFailed = false
        changed()
    }

    /// No sudoers rule yet, or one from before Low Power Mode, so turning on asks for a password
    var needsPasswordToEnable: Bool {
        !FileManager.default.fileExists(atPath: SleepSetting.rulePath) || (usesLowPower && canSetLowPower != true)
    }

    func setRequiresPower(_ required: Bool) {
        requiresPower = required
        changed()
    }

    func setRequiresInternet(_ required: Bool) {
        requiresInternet = required
        changed()
    }

    /// With a rule from before Low Power Mode, the menu then shows Finish Setup…
    func setUsesLowPower(_ on: Bool) {
        usesLowPower = on
        changed()
    }

    /// Lifts flag for one sleep
    func sleepNow() {
        pausedUntilWake = true
        pausedAt = Date()
        changed()
        // In-flight write handles it
        if !writing { requestSleep(onlyForClosedLid: false) }
    }

    /// One-time password, then enable
    private func setUpThenEnable() async {
        guard !settingUp else { return }
        settingUp = true
        defer {
            settingUp = false
            onChange?()  // the switch catches up, even if setup was cancelled
        }

        var ready = await SleepSetting.isPasswordFree()
        if ready, usesLowPower { ready = await checkLowPower() }
        if !ready {
            let prompt = "Yafie needs your password once, so it can change lid sleep and Low Power Mode "
                + "without asking again."
            switch Administrator.run(SleepSetting.installRuleCommand, prompt: prompt) {
            case .done:
                break
            case .cancelled:
                return
            case .failed(let message):
                Alert.show("Setup didn't finish", message)
                return
            }
            guard await SleepSetting.isPasswordFree() else {
                Alert.show("Setup didn't finish",
                           "The permission was added, but changing the sleep setting still asks for a password.")
                return
            }
            // Stays awake anyway
            if !(await checkLowPower()), usesLowPower {
                usesLowPower = false
                Alert.show("Low Power Mode with Lid Closed is off",
                           "The permission was added, but changing Low Power Mode still asks for a password.")
            }
        }
        isEnabled = true
        needsSetup = false
        changed()
    }

    // MARK: Events

    /// Also how the battery running low is noticed, every 30 seconds at most
    private func powerSourceMayHaveChanged() {
        let wasLow = isBatteryLow
        let onAC = PowerSource.isOnACPower
        batteryLevel = PowerSource.batteryLevel
        let switched = onAC != isOnACPower
        isOnACPower = onAC
        if switched { logger.notice("Now running on \(onAC ? "the power adapter" : "battery", privacy: .public)") }
        if isBatteryLow, !wasLow, isEnabled, !requiresPower { logger.notice("The battery is low") }
        if switched || isBatteryLow != wasLow { changed() }
    }

    private func systemDidWake() {
        pausedUntilWake = false
        isOnACPower = PowerSource.isOnACPower
        batteryLevel = PowerSource.batteryLevel
        connectivity.recheck()
        changed()
    }

    /// Backstop for missed changes
    private func recheck() {
        if lastWritten == true, PowerManager.isSleepDisabled == false {
            logger.notice("Something else turned sleep back on")
            lastWritten = nil
        }
        // Unpause if Sleep Now didn't sleep
        if pausedUntilWake, Date().timeIntervalSince(pausedAt) > 60 {
            pausedUntilWake = false
        }
        powerSourceMayHaveChanged()
        changed()
    }

    private func changed() {
        connectivity.isWatching = isEnabled && requiresInternet && !isWaitingForPower
        reconcileLowPower()  // first, so it's back before a sleep
        reconcile()
        onChange?()
    }

    // MARK: Applying the setting

    /// Match the flag to intent
    private func reconcile() {
        guard started, !terminating, !writing else { return }
        if wantsSleepDisabled {
            if lastWritten != true { write(disabled: true) }
        } else if ownsSleepDisabled, !restoreFailed {
            // Kernel may lag, so write anyway
            write(disabled: false)
        }
    }

    private func write(disabled: Bool) {
        writing = true
        let ownedBefore = ownsSleepDisabled
        if disabled {
            ownsSleepDisabled = true      // before the write, crash-safe
            sleepRequestGeneration += 1   // cancel stale sleep retries
        }
        Task {
            let succeeded = await SleepSetting.set(disabled: disabled)
            writing = false
            guard !terminating else { return }
            if succeeded {
                lastWritten = disabled
                restoreFailed = false  // writes work again
                if disabled {
                    logger.notice("Lid sleep is off")
                } else {
                    ownsSleepDisabled = false
                    logger.notice("Lid sleep is back on")
                    requestSleep(onlyForClosedLid: !pausedUntilWake)
                }
            } else if disabled {
                logger.error("Couldn't turn sleep off without a password")
                ownsSleepDisabled = ownedBefore
                needsSetup = true
            } else {
                logger.error("Couldn't turn sleep back on without a password")
                restoreWithPassword()
            }
            changed()  // catch up
        }
    }

    /// Rule broke, ask for password
    private func restoreWithPassword() {
        // Skip if already back on
        if PowerManager.isSleepDisabled != false {
            guard !systemIsPoweringOff else {
                restoreFailed = true  // next launch retries
                return
            }
            let outcome = Administrator.run("/usr/bin/pmset disablesleep 0",
                                            prompt: "Yafie needs your password to turn sleep back on.")
            guard case .done = outcome else {
                restoreFailed = true
                return
            }
        }
        lastWritten = false
        ownsSleepDisabled = false
        restoreFailed = false
        if !terminating { requestSleep(onlyForClosedLid: !pausedUntilWake) }
    }

    /// macOS won't recheck lid once flag clears
    private func requestSleep(onlyForClosedLid: Bool, attempt: Int = 1) {
        if onlyForClosedLid {
            // Respect clamshell mode
            guard !wantsSleepDisabled, PowerManager.isLidClosed == true,
                  PowerManager.lidClosingCausesSleep != false else { return }
        }
        if PowerManager.sleepNow() {
            logger.notice("Asked macOS to sleep")
            return
        }
        guard attempt < 10 else {
            logger.error("macOS refused to sleep")
            if pausedUntilWake {
                pausedUntilWake = false
                changed()
            }
            return
        }
        // Kernel lags after clearing, retry
        let generation = sleepRequestGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == sleepRequestGeneration, !terminating else { return }
            requestSleep(onlyForClosedLid: onlyForClosedLid, attempt: attempt + 1)
        }
    }

    // MARK: Low Power Mode

    /// Match Low Power Mode to the lid
    private func reconcileLowPower() {
        guard started, !terminating, !writingLowPower else { return }
        if wantsLowPower {
            if !lowPowerApplied { turnOnLowPower() }
        } else {
            lowPowerApplied = false
            // After a failure, waits for setup
            if savedLowPower != nil, canSetLowPower != false { putLowPowerBack() }
        }
    }

    private func turnOnLowPower() {
        lowPowerApplied = true
        // Still on from before, maybe a crash
        guard savedLowPower == nil else { return }
        writingLowPower = true
        Task {
            // Nothing to do without Low Power Mode, or with it on already
            if let off = await LowPowerSetting.current()?.whereOff, !terminating {
                savedLowPower = off  // before the write, crash-safe
                if await LowPowerSetting.apply(off.inLowPower) {
                    logger.notice("Low Power Mode is on, with the lid closed")
                } else {
                    logger.error("Couldn't turn on Low Power Mode without a password")
                    savedLowPower = nil  // sudo refuses them all alike, so none took
                    canSetLowPower = false  // the menu asks for setup
                    lowPowerApplied = false
                }
            }
            writingLowPower = false
            guard !terminating else { return }
            changed()  // catch up
        }
    }

    private func putLowPowerBack() {
        guard let saved = savedLowPower else { return }
        writingLowPower = true
        Task {
            let succeeded = await LowPowerSetting.apply(saved)
            writingLowPower = false
            guard !terminating else { return }
            if succeeded {
                savedLowPower = nil
                logger.notice("Low Power Mode is back as it was")
            } else {
                logger.error("Couldn't put Low Power Mode back without a password")
                canSetLowPower = false  // the menu asks for setup
            }
            changed()  // catch up
        }
    }

    /// Whether the sudoers rule covers Low Power Mode
    @discardableResult
    private func checkLowPower() async -> Bool {
        // Nothing to change without a lid
        var ready = true
        if PowerManager.isLidClosed != nil { ready = await LowPowerSetting.isPasswordFree() }
        canSetLowPower = ready
        return ready
    }
}
