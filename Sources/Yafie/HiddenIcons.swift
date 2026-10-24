import AppKit
import Carbon.HIToolbox
import os

private let iconsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "icons")

/// A ‹ in the menu bar that brings back the icons macOS hides when they don't fit. On a MacBook with a notch, icons
/// only go right of the notch, and an app whose menus run past it, like Chrome, takes that room. macOS hides the
/// leftmost icons then, and gives apps no way to show them. So the arrow puts Yafie in front with a menu bar of just
/// its name, the shortest there can be, until you're done with them. control+option+H does the same, for when even
/// the arrow doesn't fit.
@MainActor
final class HiddenIcons: NSObject {
    var onChange: (() -> Void)?
    /// Just before they come out, so Yafie's own menu can close
    var willShow: (() -> Void)?
    /// A snip editor needs Yafie to stay a regular app when they hide again
    var keepsRegular: () -> Bool = { false }

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    /// While the hidden icons are out
    private(set) var isShowing = false

    private enum Keys {
        static let enabled = "hiddenIcons"
    }
    /// The arrow's name to macOS, which keeps its place in the menu bar under it
    private static let autosaveName = "HiddenIconsArrow"
    private static let positionKey = "NSStatusItem Preferred Position \(autosaveName)"

    private var arrow: NSStatusItem?
    /// To go back to when you're done
    private var previousApp: NSRunningApplication?
    /// Whether Yafie turned regular to show them, rather than being one already for a snip editor
    private var madeRegular = false
    private var menuBar: NSMenu?
    private var watch = RevealWatch(start: 0)
    /// Times Yafie has asked macOS to come to the front since the arrow was clicked
    private var asks = 0
    /// Menus open before the arrow was clicked, which aren't the icons'
    private var openBefore: Set<CGWindowID> = []
    private var timer: Timer?
    private var activationObserver: (any NSObjectProtocol)?
    private var keyMonitor: Any?
    private var hotKey: HotKey?

    func start() {
        if isEnabled {
            addArrow()
            registerShortcut()
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            addArrow()
            registerShortcut()
        } else {
            hide(returning: true, "the arrow turned off")
            removeArrow()
            unregisterShortcut()
        }
        iconsLogger.notice("Arrow for hidden icons: \(enabled ? "on" : "off", privacy: .public)")
        onChange?()
    }

    /// Puts Yafie in front with just its name in the menu bar, so every icon that fits right of the notch shows
    func show() {
        guard isEnabled, !isShowing else { return }
        willShow?()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == Self.me ? nil : front
        // Only a regular app gets a menu bar, with a Dock icon for as long. A snip editor's is short already.
        madeRegular = NSApp.activationPolicy() != .regular
        if madeRegular {
            NSApp.setActivationPolicy(.regular)
            if NSApp.mainMenu == nil {
                let bar = Self.makeMenuBar()
                NSApp.mainMenu = bar
                menuBar = bar
            }
        }
        isShowing = true
        asks = 0
        askForMenuBar()
        updateArrow()
        watch = RevealWatch(start: ProcessInfo.processInfo.systemUptime)
        openBefore = Set(Self.openMenus())
        startWatching()
        let over = previousApp?.localizedName ?? "nothing"
        let window = arrow?.button?.window
        let place = "\(window?.frame.debugDescription ?? "nowhere")"
            + (window?.occlusionState.contains(.visible) == true ? "" : ", hidden itself")
        iconsLogger.notice("Showing hidden icons over \(over, privacy: .public), the arrow at \(place, privacy: .public)")
    }

    /// - Parameters:
    ///   - returning: back to the app you were in, if Yafie is still in front with nothing of its own open
    ///   - reason: for the log
    func hide(returning: Bool, _ reason: String) {
        guard isShowing else { return }
        isShowing = false
        stopWatching()
        updateArrow()
        let backTo = returning && Self.isIdleInFront ? previousApp : nil
        // Giving up the menu bar puts the app before in front, even over a window opened from the icons
        let keep = Self.iconAppInFront
        if madeRegular, !keepsRegular() { NSApp.setActivationPolicy(.accessory) }
        if let menuBar, NSApp.mainMenu === menuBar { NSApp.mainMenu = nil }
        menuBar = nil
        NSApp.handFocus(back: backTo)
        if let keep { Self.bringBack(keep) }
        previousApp = nil
        let back = backTo != nil ? ", back to the app before"
            : keep.map { ", keeping \($0.localizedName ?? "an app") in front" } ?? ""
        iconsLogger.notice("Hid the icons again: \(reason, privacy: .public)\(back, privacy: .public)")
    }

    /// An app with no menu bar of its own has the keyboard, like a note opened from one of the icons. It comes to the
    /// front while the menu bar stays Yafie's.
    private static var iconAppInFront: NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me,
              front.activationPolicy != .regular else { return nil }
        return front
    }

    /// Back to the front, as if from the app there now, as askForMenuBar does
    private static func bringBack(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != pid else { return }
            app.activate(from: front, options: [])
        }
    }

    /// Asks macOS to bring Yafie to the front, which gives it the menu bar. macOS 26 can turn that down while Yafie has
    /// no window open, so a moment later it asks again as if from the app in front, as Thaw does.
    private func askForMenuBar() {
        asks += 1
        NSApp.activateRegardless()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard self?.isShowing == true else { return }
            let front = NSWorkspace.shared.frontmostApplication ?? .current
            NSRunningApplication.current.activate(from: front, options: [])
        }
    }

    @objc private func clicked() {
        toggle(again: "the arrow clicked again")
    }

    private func toggle(again reason: String) {
        if isShowing {
            hide(returning: true, reason)
        } else {
            show()
        }
    }

    // MARK: Shortcut

    private func registerShortcut() {
        guard hotKey == nil else { return }
        hotKey = HotKeys.register(kVK_ANSI_H, controlKey | optionKey) { [weak self] in
            self?.toggle(again: "control+option+H again")
        }
        if hotKey == nil { iconsLogger.error("Another app is using ⌃⌥H") }
    }

    private func unregisterShortcut() {
        if let hotKey { HotKeys.unregister(hotKey) }
        hotKey = nil
    }

    // MARK: Arrow

    private func addArrow() {
        guard arrow == nil else { return }
        // Left of the system icons the first time, then wherever it's dragged. 1.1.10 started it at 0, right of them,
        // so it moves from there too.
        let defaults = UserDefaults.standard
        if (defaults.object(forKey: Self.positionKey) as? Double ?? 0) == 0 {
            let position = Self.startingPosition(controlCenter: Self.controlCenterSettings())
            defaults.set(position, forKey: Self.positionKey)
            iconsLogger.notice("The arrow starts at \(position), left of the system icons")
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.isVisible = true  // in case macOS noted it as removed
        item.button?.target = self
        item.button?.action = #selector(clicked)
        // Acts on the press, as the menu bar's other icons do
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        arrow = item
        updateArrow()
    }

    private func removeArrow() {
        guard let arrow else { return }
        // macOS forgets its place when it's removed, so it gets it back next time
        let position = UserDefaults.standard.object(forKey: Self.positionKey)
        NSStatusBar.system.removeStatusItem(arrow)
        UserDefaults.standard.set(position, forKey: Self.positionKey)
        self.arrow = nil
    }

    /// Where the arrow starts: just left of the system icons, like sound, battery and Wi-Fi, and right of other apps'
    /// icons, which macOS hides first. macOS lays icons out by the spots it keeps for them, higher further left, and
    /// puts any without one left of those. Control Center keeps the system icons' spots. Its own icon and the clock
    /// stay at the right end whatever theirs, and 0 is the right end.
    nonisolated static func startingPosition(controlCenter settings: [String: Any]) -> Double {
        let prefix = "NSStatusItem Preferred Position "
        let spots = settings.compactMap { key, value -> Double? in
            guard key.hasPrefix(prefix) else { return nil }
            let name = key.dropFirst(prefix.count)
            // Not turned off in the menu bar, under macOS 26's name or the one before
            let isShown = ["NSStatusItem VisibleCC \(name)", "NSStatusItem Visible \(name)"].allSatisfy {
                (settings[$0] as? NSNumber)?.boolValue ?? true
            }
            guard isShown, !name.hasPrefix("BentoBox"), !name.hasPrefix("Clock") else { return nil }
            return (value as? NSNumber)?.doubleValue
        }
        return spots.max().map { $0 + 1 } ?? 0
    }

    private static func controlCenterSettings() -> [String: Any] {
        let settings = CFPreferencesCopyMultiple(nil, "com.apple.controlcenter" as CFString, kCFPreferencesCurrentUser,
                                                 kCFPreferencesAnyHost)
        return settings as? [String: Any] ?? [:]
    }

    /// ‹ shows them, › hides them again
    private func updateArrow() {
        guard let button = arrow?.button else { return }
        let image = NSImage(systemSymbolName: isShowing ? "chevron.right" : "chevron.left",
                            accessibilityDescription: isShowing ? "Hide the menu bar icons again"
                                : "Show hidden menu bar icons")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        image?.isTemplate = true  // drawn in the menu bar's color
        button.image = image
        button.toolTip = isShowing ? "Hide the icons again" : "\(Yafie.name): Show the icons the menu bar hides"
    }

    /// The menu bar while they're out: Yafie's name alone, leaving them all the room there is
    private static func makeMenuBar() -> NSMenu {
        let bar = NSMenu()
        let menu = NSMenu(title: Yafie.name)
        menu.addItem(withTitle: "About \(Yafie.name)", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        // No ⌘Q, which a key press there would otherwise take
        menu.addItem(withTitle: "Quit \(Yafie.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        let item = NSMenuItem()
        item.submenu = menu
        bar.addItem(item)
        return bar
    }

    // MARK: Hiding again

    private nonisolated static let me = ProcessInfo.processInfo.processIdentifier

    /// Yafie is in front, with none of its windows taking the keyboard
    private static var isIdleInFront: Bool { NSApp.isActive && NSApp.keyWindow == nil }

    private func startWatching() {
        // You went to another app, or an icon's menu opened one
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isOther = app?.activationPolicy == .regular && app?.processIdentifier != HiddenIcons.me
            let name = app?.localizedName ?? "another app"
            MainActor.assumeIsolated { if isOther { self?.hide(returning: false, "you went to \(name)") } }
        }
        // Typing with nothing of Yafie's to type in: the keys were meant for the app you were in, so it gets them
        // back. That first key is spent doing so.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated {
                guard let self, HiddenIcons.isIdleInFront else { return false }
                self.hide(returning: true, "a key typed")
                return true
            }
            return used ? nil : event
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)  // fires while a menu is open
        self.timer = timer
    }

    private func stopWatching() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        // A snip editor that closed has made Yafie an accessory again, and given up the menu bar
        guard NSApp.activationPolicy() == .regular else { return hide(returning: false, "a snip editor closed") }
        let owner = NSWorkspace.shared.menuBarOwningApplication
        let sample = RevealWatch.Sample(
            time: ProcessInfo.processInfo.systemUptime,
            hasMenuBar: owner?.processIdentifier == Self.me,
            hasKeyWindow: NSApp.keyWindow != nil,
            isIconAppInFront: Self.iconAppInFront != nil,
            isMenuOpen: !Set(Self.openMenus()).subtracting(openBefore).isEmpty,
            isPointerInMenuBar: Self.isPointerInMenuBar)
        let hadMenuBar = watch.hadMenuBar
        let decision = watch.decide(sample)
        let asks = self.asks
        if watch.hadMenuBar, !hadMenuBar {
            let wait = String(format: "%.2f", sample.time - watch.start)
            iconsLogger.notice("Got the menu bar after \(wait, privacy: .public) s, asked \(asks) times")
        }
        switch decision {
        case .stay: break
        case .ask: askForMenuBar()  // not yet
        case .hide:
            let name = owner?.localizedName ?? "another app"
            if watch.hadMenuBar {
                hide(returning: false, "\(name) has the menu bar")
            } else {
                iconsLogger.error("macOS kept \(name, privacy: .public) in front, asked \(asks) times")
                hide(returning: false, "never got the menu bar")
            }
        case .hideAndReturn: hide(returning: true, watch.sawMenu ? "a menu closed" : "the pointer left")
        }
    }

    /// Menus, and panels hanging from icons, on screen in any app. The window list says this much without the Screen
    /// Recording permission.
    private static func openMenus() -> [CGWindowID] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows.compactMap { window in
            guard let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  RevealWatch.isMenu(layer: layer, height: frame.height) else { return nil }
            return id
        }
    }

    private static var isPointerInMenuBar: Bool {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            let height = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
            return RevealWatch.isInMenuBar(point, screen: screen.frame, barHeight: height)
        }
    }
}

/// When the icons the arrow brought back hide again: once another app has the menu bar, or the pointer has left it with
/// nothing open, soon after a menu from one of them closes, or a little longer if you only looked
struct RevealWatch {
    /// How long the pointer can be away from the menu bar, with nothing open, before they hide again
    static let lookingDelay: TimeInterval = 3
    /// The same before it has been there at all, as after the shortcut, which leaves it wherever it was
    static let reachingDelay: TimeInterval = 6
    /// The same, once a menu from one of them has closed
    static let doneDelay: TimeInterval = 1
    /// How long macOS has to bring Yafie to the front. Until then, the app you were in has the menu bar.
    static let takeOverDelay: TimeInterval = 1.5

    enum Decision: Equatable {
        case stay
        /// Ask macOS again to bring Yafie to the front
        case ask
        /// You went to another app, which keeps the focus
        case hide
        /// Back to the app you were in
        case hideAndReturn
    }

    struct Sample {
        let time: TimeInterval
        /// The menu bar is Yafie's, the short one
        var hasMenuBar = true
        /// One of Yafie's windows has the keyboard, like the tuner opened from its own icon
        var hasKeyWindow = false
        /// An app with no menu bar of its own is in front, like a note opened from one of the icons
        var isIconAppInFront = false
        /// A menu, or a panel hanging from an icon, is open
        var isMenuOpen = false
        var isPointerInMenuBar = false
    }

    let start: TimeInterval
    /// macOS has given Yafie the menu bar since the arrow was clicked
    private(set) var hadMenuBar = false
    /// A menu has opened since they came out
    private(set) var sawMenu = false
    /// The pointer has been in the menu bar since they came out
    private(set) var wasInMenuBar = false
    private var awaySince: TimeInterval?

    init(start: TimeInterval) {
        self.start = start
    }

    mutating func decide(_ sample: Sample) -> Decision {
        guard sample.hasMenuBar else {
            // Another app took it, or macOS hasn't handed it over yet
            return hadMenuBar || sample.time - start >= Self.takeOverDelay ? .hide : .ask
        }
        hadMenuBar = true
        if sample.isMenuOpen { sawMenu = true }
        if sample.isPointerInMenuBar { wasInMenuBar = true }
        guard !sample.hasKeyWindow, !sample.isIconAppInFront, !sample.isMenuOpen, !sample.isPointerInMenuBar else {
            awaySince = nil
            return .stay
        }
        let since = awaySince ?? sample.time
        awaySince = since
        let delay = sawMenu ? Self.doneDelay : wasInMenuBar ? Self.lookingDelay : Self.reachingDelay
        return sample.time - since >= delay ? .hideAndReturn : .stay
    }

    /// A menu, or a popover or panel an icon opened, from its window's level and height. Menu bar icons themselves
    /// sit at the status level, but are never taller than the menu bar.
    static func isMenu(layer: Int, height: CGFloat) -> Bool {
        let menu = Int(CGWindowLevelForKey(.popUpMenuWindow))
        if layer == menu || layer == menu - 1 { return true }
        let menuBar = [CGWindowLevelForKey(.statusWindow), CGWindowLevelForKey(.mainMenuWindow)].map { Int($0) }
        return menuBar.contains(layer) && height > 40
    }

    /// In a screen's menu bar, with a little to spare below it
    static func isInMenuBar(_ point: CGPoint, screen: CGRect, barHeight: CGFloat) -> Bool {
        // A usual height while the menu bar is hidden, as in full screen
        let height = max(barHeight, 24)
        return point.x >= screen.minX && point.x <= screen.maxX
            && point.y <= screen.maxY && point.y >= screen.maxY - height - 6
    }
}
