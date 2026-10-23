import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = LidAwakeController()
    private let updater = Updater()
    private let snapper = WindowSnapper()
    private let snipper = ScreenSnipper()
    private let previews = AppPreview()
    private let cleaner = KeyboardCleaner()
    private let hiddenIcons = HiddenIcons()
    private lazy var drums = DrumMachineWindowController()
    private lazy var tuner: TunerWindowController = {
        let tuner = TunerWindowController()
        tuner.onLoudnessChange = { [weak self] in self?.updateIcon() }
        return tuner
    }()
    private var statusItem: NSStatusItem?
    private var signalSources: [any DispatchSourceSignal] = []
    /// The menu bar icon's menu. Switches stay put when flipped, so the open menu updates in place.
    private let menu = MenuPanelController()
    /// Alerts and prompts wait for the menu to close
    private var afterMenuCloses: (@MainActor () -> Void)?
    /// A termination signal quits without asking about unsaved snips
    private var isQuittingForSignal = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(toggleMenu)
        // Opens on the press, as a menu does
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem = item
        menu.willOpen = { [weak self] in self?.menuWillOpen() }
        menu.didClose = { [weak self] in self?.menuDidClose() }
        menu.model.onToggle = { [weak self] toggle, on in self?.flip(toggle, on) }
        menu.model.onCommand = { [weak self] command in self?.run(command) }

        controller.onChange = { [weak self] in
            self?.updateIcon()
            self?.refreshMenu()
        }
        controller.start()
        snapper.onChange = { [weak self] in self?.refreshMenu() }
        snapper.start()
        previews.onChange = { [weak self] in self?.refreshMenu() }
        previews.start()
        snipper.onChange = { [weak self] in self?.refreshMenu() }
        snipper.start()
        hiddenIcons.onChange = { [weak self] in self?.refreshMenu() }
        hiddenIcons.willShow = { [weak self] in self?.menu.close() }
        hiddenIcons.keepsRegular = { [weak self] in self?.snipper.editors.isOpen ?? false }
        hiddenIcons.start()
        updateIcon()
        quitOnTerminationSignals()
        // After an update that moved the app to a new name
        Updater.keepOpenAtLogin()
        // A second copy asks this one to speak up
        DistributedNotificationCenter.default().addObserver(forName: Yafie.showMenuNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showMenu() }
        }
        #if DEBUG
        // Test hooks: Yafie --update-now, Yafie --tuner, Yafie --drums, Yafie --snip-editor <image file>,
        // Yafie --show-hidden-icons (with the arrow on, after 3 seconds)
        let arguments = CommandLine.arguments
        if arguments.contains("--update-now") { updater.checkForUpdates(askFirst: false) }
        if arguments.contains("--tuner") { tuner.show() }
        if arguments.contains("--drums") { drums.show() }
        if arguments.contains("--show-hidden-icons") {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.hiddenIcons.show()
            }
        }
        if let index = arguments.firstIndex(of: "--snip-editor"), arguments.indices.contains(index + 1),
           let data = FileManager.default.contents(atPath: arguments[index + 1]), let snip = Snip(data: data) {
            snipper.editors.open(snip, returningTo: nil)
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    /// Opened again from Finder, or its Dock icon clicked while an editor is open
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Updater.isStale {
            logger.notice("A different version was installed, restarting")
            Updater.relaunch()
        } else if snipper.editors.isOpen {
            snipper.editors.bringForward()
        } else {
            showMenu()
        }
        return false
    }

    /// Snips with shapes that haven't been copied or saved get a chance first
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = snipper.editors.unsaved
        guard unsaved > 0, !isQuittingForSignal else { return .terminateNow }
        NSApp.activateRegardless()
        let alert = NSAlert()
        alert.messageText = unsaved == 1 ? "Quit without saving your snip?" : "Quit without saving \(unsaved) snips?"
        alert.informativeText = "Shapes you haven't copied or saved will be lost."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func showMenu() {
        // After the Apple event returns
        DispatchQueue.main.async { [weak self] in self?.statusItem?.button?.performClick(nil) }
    }

    // MARK: Menu

    @objc private func toggleMenu() {
        guard let button = statusItem?.button else { return }
        menu.toggle(from: button)
    }

    private func menuWillOpen() {
        // The permissions may have changed in System Settings
        snapper.refresh()
        previews.refresh()
        snipper.refresh()
        refreshMenu(force: true)
    }

    private func menuDidClose() {
        guard let work = afterMenuCloses else { return }
        afterMenuCloses = nil
        // Once the panel is gone
        Task { @MainActor in work() }
    }

    /// Matches the open menu to the current state
    private func refreshMenu(force: Bool = false) {
        guard force || menu.isOpen else { return }
        let model = menu.model
        let status = controller.status
        model.stayAwakeSummary = status.summary
        model.stayAwakeBadge = status.badge
        model.isOn = [
            .appPreviews: previews.isEnabled,
            .snapWindows: snapper.isEnabled,
            .snapThirds: snapper.usesThirds,
            .snipScreen: snipper.isEnabled,
            .hiddenIcons: hiddenIcons.isEnabled,
            .stayAwake: controller.isEnabled,
            .requirePower: controller.requiresPower,
            .requireInternet: controller.requiresInternet,
            .lowPower: controller.usesLowPower,
            .openAtLogin: SMAppService.mainApp.status == .enabled,
        ]
        var disabled: Set<MenuToggle> = []
        // Only mean something while the main switch is on
        if !controller.isEnabled { disabled.formUnion([.requirePower, .requireInternet, .lowPower]) }
        if !snapper.isEnabled { disabled.insert(.snapThirds) }
        model.isDisabled = disabled

        // Sleep Now, Finish Setup… or Turn Sleep Back On…, when the status calls for one
        model.stayAwakeAction = switch status {
        case .active: MenuAction(title: "Sleep Now", command: .sleepNow)
        case .needsSetup, .lowPowerNeedsSetup: MenuAction(title: "Finish Setup…", command: .finishSetup)
        case .restoreFailed: MenuAction(title: "Turn Sleep Back On…", command: .retryRestore)
        case .off, .waitingForPower, .lowBattery, .waitingForInternet: nil
        }
        // Why the shortcut didn't take
        model.snapAction = snapper.status == .shortcutTaken
            ? MenuAction(title: "Another app is using a control+option+arrow key") : nil
        // Allow Screen Snipping…, or why the shortcut didn't take, when the status calls for one
        model.snipAction = switch snipper.status {
        case .needsPermission: MenuAction(title: "Allow Screen Snipping…", command: .allowScreenSnipping)
        case .shortcutTaken: MenuAction(title: "Another app is using control+option+P")
        case .off, .on: nil
        }
        model.isCheckingForUpdates = updater.isBusy
    }

    private func closeMenu(then work: @escaping @MainActor () -> Void) {
        guard menu.isOpen else {
            Task { @MainActor in work() }
            return
        }
        afterMenuCloses = work
        menu.close()
    }

    private func flip(_ toggle: MenuToggle, _ on: Bool) {
        switch toggle {
        case .appPreviews: setAppPreviews(on)
        case .snapWindows: setSnapWindows(on)
        case .snapThirds: snapper.setUsesThirds(on)
        case .snipScreen: setSnipScreen(on)
        case .hiddenIcons: hiddenIcons.setEnabled(on)
        case .stayAwake: setStayAwake(on)
        case .requirePower: controller.setRequiresPower(on)
        case .requireInternet: controller.setRequiresInternet(on)
        case .lowPower: controller.setUsesLowPower(on)
        case .openAtLogin: setOpenAtLogin(on)
        }
        // Back to how things are, if the feature didn't take it
        refreshMenu()
    }

    /// Buttons close the menu first, as a menu's items do
    private func run(_ command: MenuCommand) {
        closeMenu { [weak self] in
            guard let self else { return }
            switch command {
            case .allowScreenSnipping: snipper.openScreenRecordingSettings()
            case .openTuner: tuner.show()
            case .openDrums: drums.show()
            case .cleanKeyboard: cleaner.start()
            case .sleepNow: controller.sleepNow()
            case .finishSetup: controller.finishSetup()
            case .retryRestore: controller.retryRestore()
            case .showAbout: showAbout()
            case .checkForUpdates: updater.checkForUpdates()
            case .quit: NSApp.terminate(nil)
            }
        }
    }

    private func setStayAwake(_ on: Bool) {
        if on, controller.needsPasswordToEnable {
            // The password prompt needs the screen
            closeMenu { [weak self] in self?.controller.setEnabled(true) }
        } else {
            controller.setEnabled(on)
        }
    }

    private func setSnapWindows(_ on: Bool) {
        if on, !AXIsProcessTrusted() {
            // macOS's permission dialog needs the screen
            closeMenu { [weak self] in self?.snapper.setEnabled(true) }
        } else {
            snapper.setEnabled(on)
        }
    }

    private func setAppPreviews(_ on: Bool) {
        if on, !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() {
            // macOS's permission dialog needs the screen
            closeMenu { [weak self] in self?.previews.setEnabled(true) }
        } else {
            previews.setEnabled(on)
        }
    }

    private func setSnipScreen(_ on: Bool) {
        if on, !CGPreflightScreenCaptureAccess() {
            // macOS's permission dialog needs the screen
            closeMenu { [weak self] in self?.snipper.setEnabled(true) }
        } else {
            snipper.setEnabled(on)
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            try on ? service.register() : service.unregister()
        } catch {
            let message = error.localizedDescription
            closeMenu { Alert.show("Couldn't change Open at Login", message) }
        }
        if service.status == .requiresApproval {
            closeMenu { SMAppService.openSystemSettingsLoginItems() }
        }
        refreshMenu()
    }

    @objc func showAbout() {
        NSApp.activate()
        // Empty build number drops the "(1)"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: Yafie.fullName,
                                                     .applicationVersion: Bundle.main.shortVersion, .version: ""])
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        // A colored icon says the tuner is open, and how loud a sound it hears
        if let loudness = tuner.loudness {
            let image = loudness.icon
            image?.accessibilityDescription = "Tuner open, \(loudness.spoken)"
            button.image = image
            button.toolTip = "\(Yafie.name): Tuner is open"
            return
        }
        let status = controller.status
        let image = status.icon
        image?.isTemplate = true  // drawn in the menu bar's color
        image?.accessibilityDescription = status.summary
        // At full strength like the menu bar's other icons, even while off
        button.image = image
        button.toolTip = "\(Yafie.name): \(status.summary)"
    }

    /// Clean quit restores sleep
    private func quitOnTerminationSignals() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.isQuittingForSignal = true
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

private extension LidAwakeController.Status {
    var summary: String {
        switch self {
        case .off: "Off: closing the lid sleeps your Mac"
        case .waitingForPower: "On battery: sleeps normally until plugged in"
        case .lowBattery: "Battery low: sleeps normally until plugged in"
        case .waitingForInternet: "Offline: sleeps normally until back online"
        case .active(let onBattery):
            onBattery ? "On battery: stays awake with the lid closed" : "Plugged in: stays awake with the lid closed"
        case .needsSetup: "Needs your password once to finish setup"
        case .lowPowerNeedsSetup: "Needs your password once more for Low Power Mode"
        case .restoreFailed: "Couldn't turn sleep back on"
        }
    }

    /// The pill beside Stay Awake in the menu
    var badge: MenuBadge {
        switch self {
        case .off: MenuBadge(title: "Off", symbol: "moon.fill", tone: .plain)
        case .waitingForPower: MenuBadge(title: "Waiting", symbol: "bolt.slash.fill", tone: .plain)
        case .lowBattery: MenuBadge(title: "Low Battery", symbol: "battery.25", tone: .caution)
        case .waitingForInternet: MenuBadge(title: "Offline", symbol: "wifi.slash", tone: .plain)
        case .active: MenuBadge(title: "Awake", symbol: "sun.max.fill", tone: .good)
        case .needsSetup, .lowPowerNeedsSetup: MenuBadge(title: "Setup", symbol: "key.fill", tone: .caution)
        case .restoreFailed: MenuBadge(title: "Problem", symbol: "exclamationmark.triangle.fill", tone: .alert)
        }
    }

    /// The icon, filled while it keeps the Mac awake
    var icon: NSImage? {
        switch self {
        case .off, .waitingForPower, .lowBattery, .waitingForInternet: NSImage(named: "MenuIconOutline")
        case .active: NSImage(named: "MenuIcon")
        case .needsSetup, .lowPowerNeedsSetup, .restoreFailed:
            NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        }
    }
}

private extension LoudnessMeter.Loudness {
    /// The filled icon: green while it's quiet or soft, then bright yellow, orange or red
    var icon: NSImage? {
        guard let glyph = NSImage(named: "MenuIcon") else { return nil }
        let color: NSColor = switch self {
        case .quiet, .soft: .systemGreen
        case .medium: .systemYellow
        case .loud: .systemOrange
        case .veryLoud: .systemRed
        }
        let image = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false  // keeps its color
        return image
    }

    var spoken: String {
        switch self {
        case .quiet: "quiet"
        case .soft: "hearing a soft sound"
        case .medium: "hearing a medium sound"
        case .loud: "hearing a loud sound"
        case .veryLoud: "hearing a very loud sound"
        }
    }
}

@MainActor
enum Alert {
    static func show(_ title: String, _ message: String) {
        NSApp.activateRegardless()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    static func confirm(_ title: String, _ message: String, button: String, cancel: String = "Not Now") -> Bool {
        NSApp.activateRegardless()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension NSApplication {
    /// Comes to the front, over the app you're in. Since macOS 14, activate() is only a request, and macOS turns it
    /// down when what Yafie shows comes after a wait, like an update check, or from a pop-up menu, like a snip's
    /// choices. Then an alert opens behind the app you're in and seems stuck. This one isn't a request.
    func activateRegardless() {
        activate(ignoringOtherApps: true)
    }

    /// Gives the focus back to the app you were in, the cooperative way: Yafie yields it, then asks for the hand-off
    func handFocus(back app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        yieldActivation(to: app)
        app.activate(from: .current, options: [])
    }
}
