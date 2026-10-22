import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem
import SwiftUI
import os

private let cleanLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "clean")

/// Turns the keyboard and trackpad off while you wipe them, for 5 minutes or until both ⌘ keys are held down for 3
/// seconds. A window in the middle of the screen counts down.
@MainActor
final class KeyboardCleaner {
    private let model = CleaningModel()
    private lazy var panel = makePanel()
    private var session: CleaningSession? {
        didSet { if let session { model.session = session } }
    }
    /// Fires when the session would end
    private var timer: Timer?
    private var previousApp: NSRunningApplication?

    /// Asks first. Like window snapping, it needs Accessibility, here to hold back what you type and click.
    func start() {
        guard session == nil else { return }
        guard AXIsProcessTrusted() else {
            // macOS's own dialog, pointing to Privacy & Security → Accessibility. The key is
            // kAXTrustedCheckOptionPrompt's value: Swift 6 won't read that C global.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        guard Alert.confirm("Turn off the keyboard and trackpad?",
                            "They stay off for 5 minutes while you clean them. To turn them back on sooner, hold down "
                                + "both ⌘ keys for 3 seconds.",
                            button: "Turn Off", cancel: "Cancel") else {
            return NSApp.handFocus(back: previousApp)
        }
        guard InputBlocker.start(onCommandKeys: { [weak self] down in self?.commandKeys(down) }) else {
            cleanLogger.error("Couldn't create the event tap")
            Alert.show("Couldn't turn off the keyboard and trackpad",
                       "Turn Yafie off and back on in System Settings → Privacy & Security → Accessibility, then try "
                           + "again.")
            return NSApp.handFocus(back: previousApp)
        }
        if IsSecureEventInputEnabled() { cleanLogger.notice("Secure input is on, so keys can get past the tap") }
        self.previousApp = previousApp
        session = CleaningSession(start: Date())
        show()
        schedule()
        cleanLogger.notice("Keyboard and trackpad off")
    }

    /// In the middle of the screen with the pointer. Secure input, as in a password field, hides keystrokes from event
    /// taps, so it takes the keyboard: that ends another app's secure input, and any key that gets past lands here.
    private func show() {
        let pointer = NSEvent.mouseLocation
        if let area = (NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main)?.frame {
            panel.setFrameOrigin(NSPoint(x: (area.midX - panel.frame.width / 2).rounded(),
                                         y: (area.midY - panel.frame.height / 2).rounded()))
        }
        NSApp.activateRegardless()
        panel.makeKeyAndOrderFront(nil)
        let message = "Keyboard and trackpad off for 5 minutes. Hold down both Command keys for 3 seconds to turn "
            + "them back on."
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func commandKeys(_ down: Bool) {
        session?.commandKeys(down: down, at: Date())
        schedule()
    }

    /// Ends the session, or checks again when it would end
    private func schedule() {
        timer?.invalidate()
        guard let session else { return }
        guard !session.isOver(at: Date()) else { return stop() }
        let timer = Timer(fire: session.deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        RunLoop.main.add(timer, forMode: .common)  // fires while an alert is up
        self.timer = timer
    }

    private func stop() {
        guard let session else { return }
        InputBlocker.stop()
        timer?.invalidate()
        timer = nil
        self.session = nil
        panel.orderOut(nil)
        let reason = Date() >= session.end ? "after 5 minutes" : "from both ⌘ keys"
        cleanLogger.notice("Keyboard and trackpad back on, \(reason, privacy: .public)")
        NSApp.handFocus(back: previousApp)
        previousApp = nil
        Toast.show("Keyboard and trackpad are back on", near: NSEvent.mouseLocation)
    }

    private func makePanel() -> NSPanel {
        let panel = CleaningPanel(contentRect: NSRect(origin: .zero, size: CleaningView.size), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = .roundedMask(radius: 16)
        let content = NSHostingView(rootView: CleaningView(model: model))
        content.frame = NSRect(origin: .zero, size: CleaningView.size)
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        panel.contentView = background
        return panel
    }
}

/// Borderless, yet it takes the keyboard
private final class CleaningPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Without a beep
    override func keyDown(with event: NSEvent) {}
}

// MARK: Event tap

/// Holds back every key press, click, scroll and gesture, from every keyboard, trackpad and mouse, with an event tap
/// where input enters the window server. It needs Accessibility. Its source is on the main run loop on purpose: if the
/// main thread hangs, macOS turns the tap off by itself, so input can't stay held back.
@MainActor
enum InputBlocker {
    private static var tap: CFMachPort?
    private static var source: CFRunLoopSource?
    private static var onCommandKeys: ((Bool) -> Void)?
    private static var commandKeysDown = false

    /// Calls onCommandKeys with whether both ⌘ keys are down, each time that changes. False without Accessibility.
    static func start(onCommandKeys: @escaping (Bool) -> Void) -> Bool {
        stop()
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let flags = event.flags
            // Its source is on the main run loop
            let passes = MainActor.assumeIsolated { InputBlocker.received(type, flags) }
            return passes ? Unmanaged.passUnretained(event) : nil
        }
        // Where events enter the window server, before the pointer moves. Then where they enter the login session.
        guard let tap = [CGEventTapLocation.cghidEventTap, .cgSessionEventTap].lazy.compactMap({ location in
            CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: .max,
                              callback: callback, userInfo: nil)
        }).first else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)  // also while an alert is up
        self.tap = tap
        self.source = source
        self.onCommandKeys = onCommandKeys
        return true
    }

    static func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        onCommandKeys = nil
        commandKeysDown = false
    }

    /// Whether the event goes on to macOS and the apps
    private static func received(_ type: CGEventType, _ flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned it off, after a hang. Yafie is answering again.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .flagsChanged:
            let down = CleaningSession.bothCommandKeys(flags)
            if down != commandKeysDown {
                commandKeysDown = down
                onCommandKeys?(down)
            }
            return false
        case .null:
            return true
        default:
            return false
        }
    }
}

// MARK: Session

/// When cleaning ends: after 5 minutes, or once both ⌘ keys have been held down for 3 seconds
struct CleaningSession: Equatable {
    static let duration: TimeInterval = 5 * 60
    static let hold: TimeInterval = 3

    let start: Date
    /// When both ⌘ keys went down, while they're still down
    private(set) var heldSince: Date?

    init(start: Date) {
        self.start = start
    }

    var end: Date { start + Self.duration }
    /// When it ends, unless the ⌘ keys change first
    var deadline: Date { heldSince.map { min($0 + Self.hold, end) } ?? end }

    func isOver(at time: Date) -> Bool { time >= deadline }

    mutating func commandKeys(down: Bool, at time: Date) {
        if !down {
            heldSince = nil
        } else if heldSince == nil {
            heldSince = time
        }
    }

    /// Both the left and the right ⌘ key, from an event's device-dependent flags
    static func bothCommandKeys(_ flags: CGEventFlags) -> Bool {
        let both = UInt64(NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK)
        return flags.rawValue & both == both
    }

    /// "4:59", to the nearest second
    static func countdown(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

// MARK: Window

/// What the cleaning window shows
@Observable @MainActor
final class CleaningModel {
    var session = CleaningSession(start: Date())
}

struct CleaningView: View {
    static let size = CGSize(width: 400, height: 250)
    private static let barWidth: CGFloat = 200

    let model: CleaningModel

    var body: some View {
        let session = model.session
        let isHolding = session.heldSince != nil
        VStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Keyboard and trackpad are off")
                .font(.system(size: 20, weight: .bold))
            // Ticks on the session's whole seconds
            TimelineView(.periodic(from: session.start, by: 1)) { context in
                Text("Back on in \(CleaningSession.countdown(session.end.timeIntervalSince(context.date)))")
                    .font(.system(size: 15))
                    .monospacedDigit()
            }
            Text("Hold down both ⌘ keys for 3 seconds to turn them on now.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // Fills while both ⌘ keys are down
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor).frame(width: isHolding ? Self.barWidth : 0)
            }
            .frame(width: Self.barWidth, height: 6)
            .animation(isHolding ? .linear(duration: CleaningSession.hold) : .easeOut(duration: 0.2), value: isHolding)
            .padding(.top, 6)
        }
        .padding(30)
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
