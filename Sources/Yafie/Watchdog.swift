import Foundation

/// Restores sleep, and Low Power Mode, if app dies
@MainActor
final class Watchdog {
    static let argument = "--watchdog"

    var ownsSleepDisabled = false {
        didSet { send() }
    }
    /// What to put Low Power Mode back to
    var savedLowPower: LowPowerSetting? {
        didSet { send() }
    }
    private var process: Process?
    private var pipe: FileHandle?

    func start(ownsSleepDisabled: Bool, savedLowPower: LowPowerSetting?) {
        self.ownsSleepDisabled = ownsSleepDisabled
        self.savedLowPower = savedLowPower
        launch()
    }

    private func launch() {
        try? pipe?.close()
        pipe = nil
        guard let executable = Bundle.main.executableURL else { return }

        let channel = Pipe()
        let input = channel.fileHandleForWriting
        // EPIPE instead of SIGPIPE
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        // Keep out of child processes
        _ = fcntl(input.fileDescriptor, F_SETFD, FD_CLOEXEC)

        let process = Process()
        process.executableURL = executable
        process.arguments = [Self.argument]
        process.standardInput = channel.fileHandleForReading
        process.terminationHandler = { [weak self] _ in
            // Someone killed it, respawn
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))  // throttle
                self?.launch()
            }
        }
        do {
            try process.run()
        } catch {
            logger.error("Couldn't start the watchdog: \(error.localizedDescription, privacy: .public)")
            return
        }
        try? channel.fileHandleForReading.close()  // child's end
        self.process = process
        pipe = input
        send()
    }

    private func send() {
        // Respawn resends state, like "1 lowpowermode -b 0 -c 0"
        let line = [ownsSleepDisabled ? "1" : "0", savedLowPower?.description].compactMap { $0 }.joined(separator: " ")
        try? pipe?.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Child side, blocks until EOF
    static func run() {
        // Must outlive the app
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
        }
        var owned = false
        var savedLowPower: LowPowerSetting?
        while let line = readLine() {
            owned = line.hasPrefix("1")
            savedLowPower = LowPowerSetting(line.dropFirst(2))
        }
        guard owned || savedLowPower != nil else { return }

        // Let in-flight writes land
        Thread.sleep(forTimeInterval: 1)
        // First, since sleep may follow
        if let savedLowPower {
            logger.notice("Yafie quit without putting Low Power Mode back")
            if LowPowerSetting.applySynchronously(savedLowPower) {
                logger.notice("The watchdog put Low Power Mode back")
            } else {
                logger.error("The watchdog couldn't put Low Power Mode back")
            }
        }
        guard owned else { return }
        logger.notice("Yafie quit without turning sleep back on")
        guard SleepSetting.setSynchronously(disabled: false) else {
            logger.error("The watchdog couldn't turn sleep back on")
            return
        }
        logger.notice("The watchdog turned sleep back on")

        // Same lid check as app
        guard PowerManager.isLidClosed == true, PowerManager.lidClosingCausesSleep != false else { return }
        for _ in 1...10 {  // kernel lags after clearing
            if PowerManager.sleepNow() {
                logger.notice("The watchdog asked macOS to sleep")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        logger.error("macOS refused to sleep")
    }
}
