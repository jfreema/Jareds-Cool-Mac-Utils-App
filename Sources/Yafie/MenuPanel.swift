import AppKit
import SwiftUI

// MARK: Model

/// A switch in the menu
enum MenuToggle: Hashable {
    case appPreviews, snapWindows, snapThirds, snipScreen, hiddenIcons
    case stayAwake, requirePower, requireInternet, lowPower
    case openAtLogin
}

/// What a button in the menu does
enum MenuCommand {
    case allowScreenSnipping
    case openTuner, openDrums, cleanKeyboard
    case finishSetup, retryRestore
    case showAbout, checkForUpdates, quit
}

/// A button under a feature's switches, or a note when there's nothing to press
struct MenuAction: Equatable {
    let title: String
    var command: MenuCommand?
}

/// The pill beside Stay Awake that says what it's doing
struct MenuBadge: Equatable {
    enum Tone { case plain, good, caution, alert }
    let title: String
    let symbol: String
    let tone: Tone
}

/// What the menu shows. AppDelegate fills it in, and hears back through onToggle and onCommand.
@Observable @MainActor
final class MenuModel {
    var isOn: [MenuToggle: Bool] = [:]
    var isDisabled: Set<MenuToggle> = []
    var snapAction: MenuAction?
    var snipAction: MenuAction?
    var stayAwakeSummary = ""
    var stayAwakeBadge = MenuBadge(title: "Off", symbol: "moon.fill", tone: .plain)
    var stayAwakeAction: MenuAction?
    var isCheckingForUpdates = false
    /// The row under the pointer, highlighted as a menu's would be
    var hovered: String?

    @ObservationIgnored var onToggle: (MenuToggle, Bool) -> Void = { _, _ in }
    @ObservationIgnored var onCommand: (MenuCommand) -> Void = { _ in }
    @ObservationIgnored var onResize: (CGSize) -> Void = { _ in }

    /// Flips at once, then AppDelegate puts it right if the feature says otherwise
    func binding(_ toggle: MenuToggle) -> Binding<Bool> {
        Binding(get: { self.isOn[toggle] ?? false }, set: { on in
            self.isOn[toggle] = on
            self.onToggle(toggle, on)
        })
    }

    func hover(_ id: String, _ inside: Bool) {
        if inside {
            hovered = id
        } else if hovered == id {
            hovered = nil
        }
    }
}

// MARK: Panel

/// The menu bar icon's menu: a panel drawn in the bubble pop style, since an NSMenu can't have its own colors,
/// outlines or shadows. It behaves like a menu: it drops from the icon, never activates the app, and closes on a
/// click elsewhere, Esc, or a second click on the icon. Switches stay put when flipped, and buttons close it first.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    let model = MenuModel()
    /// Before it opens, to catch up on permissions changed in System Settings
    var willOpen: (() -> Void)?
    var didClose: (() -> Void)?

    private lazy var panel = makePanel()
    private lazy var content = NSHostingController(rootView: MenuView(model: model))
    private weak var button: NSStatusBarButton?
    private var clickMonitor: Any?
    /// A click on the icon closes the panel by taking the focus, and then mustn't open it again
    private var closedAt: TimeInterval = 0
    /// All of the menu. On a screen too short for it, the panel is shorter and scrolls.
    private var contentSize = CGSize(width: MenuView.width, height: 400)

    var isOpen: Bool { panel.isVisible }

    func toggle(from button: NSStatusBarButton) {
        if isOpen {
            close()
            return
        }
        guard ProcessInfo.processInfo.systemUptime - closedAt > 0.3 else { return }
        self.button = button
        willOpen?()
        contentSize = content.sizeThatFits(in: NSSize(width: MenuView.width, height: 10_000))
        place()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
                                                                    .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        closedAt = ProcessInfo.processInfo.systemUptime
        button?.highlight(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        didClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// Hangs from the icon, like a menu, and inside the screen
    private func place() {
        guard let anchor = button?.window?.frame,
              let screen = button?.window?.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let top = min(anchor.minY - 4, area.maxY)
        let height = min(contentSize.height.rounded(.up), top - area.minY - 6)
        let x = min(max(anchor.minX, area.minX + 6), area.maxX - MenuView.width - 6)
        panel.setFrame(NSRect(x: x.rounded(), y: (top - height).rounded(), width: MenuView.width, height: height),
                       display: true)
        panel.invalidateShadow()
    }

    private func makePanel() -> NSPanel {
        let panel = MenuPanel(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.onCancel = { [weak self] in self?.close() }
        // The panel follows the menu's height itself, keeping its top under the icon
        content.sizingOptions = []
        panel.contentViewController = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        model.onResize = { [weak self] size in
            guard let self, size != self.contentSize else { return }
            self.contentSize = size
            if self.panel.isVisible { self.place() }
        }
        return panel
    }
}

/// Takes the keyboard without activating the app, so Esc closes it and ⌘Q quits, as in a menu
private final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 {  // Esc
                onCancel?()
                return
            }
            if modifiers == .command, event.charactersIgnoringModifiers == "q" {
                NSApp.terminate(nil)
                return
            }
        }
        super.sendEvent(event)
    }
}

// MARK: Views

struct MenuView: View {
    static let width: CGFloat = 400

    let model: MenuModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        // Scrolls on a screen too short for all of it
        ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical) { content }
        }
        .frame(width: Self.width)
        .background(Bubble.blue)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Bubble.ink, lineWidth: 2.5))
        .onPreferenceChange(MenuSizeKey.self) { size in
            MainActor.assumeIsolated { model.onResize(size) }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            section("App Preview") {
                card {
                    ToggleRow(model: model, toggle: .appPreviews, title: "Show App Previews in the Dock")
                }
            }
            section("Windows") {
                card {
                    ToggleRow(model: model, toggle: .snapWindows, title: "Snap Windows with control+option+arrow keys")
                    OptionStrip {
                        OptionChip(model: model, toggle: .snapThirds, title: "Thirds on External Displays",
                                   help: "Three columns instead of two on external displays")
                    }
                    if let action = model.snapAction { ActionRow(model: model, action: action) }
                }
            }
            section("Screenshots") {
                card {
                    ToggleRow(model: model, toggle: .snipScreen, title: "Snipping Tool with control+option+P")
                    if let action = model.snipAction { ActionRow(model: model, action: action) }
                }
            }
            section("Menu Bar") {
                card {
                    ToggleRow(model: model, toggle: .hiddenIcons, title: "Show Hidden Icons with control+option+H")
                }
            }
            section("Tools") {
                HStack(spacing: 8) {
                    ToolTile(title: "Guitar Tuner", symbol: "tuningfork", chip: Bubble.yellow) {
                        model.onCommand(.openTuner)
                    }
                    ToolTile(title: "Drum Machine", symbol: "music.quarternote.3", chip: Bubble.green) {
                        model.onCommand(.openDrums)
                    }
                    ToolTile(title: "Clean Keyboard", symbol: "sparkles", chip: Bubble.orange) {
                        model.onCommand(.cleanKeyboard)
                    }
                    .accessibilityLabel("Clean Keyboard and Trackpad")
                }
                .padding(.trailing, 2)
            }
            section("Stay Awake", badge: model.stayAwakeBadge) {
                card {
                    StatusRow(model: model)
                    ToggleRow(model: model, toggle: .stayAwake, title: "Stay Awake with Lid Closed")
                    OptionStrip {
                        OptionChip(model: model, toggle: .requirePower, title: "Plugged In Only",
                                   help: "Stays awake only while connected to power")
                        OptionChip(model: model, toggle: .requireInternet, title: "Online Only",
                                   help: "Stays awake only while connected to the internet")
                        OptionChip(model: model, toggle: .lowPower, title: "Low Power Mode",
                                   help: "Turns on Low Power Mode while the lid is closed")
                    }
                }
            }

            footer
                .padding(.top, 2)
        }
        .padding(12)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: MenuSizeKey.self, value: geometry.size)
        })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Bubble.ink)
                .frame(width: 22, height: 22)
                .bubbleCard(fill: Bubble.orange, radius: 6, lift: 2)
                .accessibilityHidden(true)
            Text("Jared's Cool Mac App")
                .font(Bubble.display(19))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.white)
                .shadow(color: Bubble.ink, radius: 0, x: 1.5, y: 2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            OptionChip(model: model, toggle: .openAtLogin, title: "Open at Login",
                       help: "Opens \(Yafie.name) when you log in")
        }
        .padding(.trailing, 2)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("About") { model.onCommand(.showAbout) }
                .buttonStyle(BubbleButtonStyle())
            Button(model.isCheckingForUpdates ? String("Checking…") : String("Check for Updates")) {
                model.onCommand(.checkForUpdates)
            }
            .buttonStyle(BubbleButtonStyle())
            .disabled(model.isCheckingForUpdates)
            Spacer(minLength: 0)
            Button { model.onCommand(.quit) } label: {
                HStack(spacing: 5) {
                    Text("Quit")
                    Text("⌘Q").font(Bubble.body(10.5)).opacity(0.6)
                }
            }
            .buttonStyle(BubbleButtonStyle(fill: Bubble.yellow))
            .accessibilityLabel("Quit \(Yafie.name)")
        }
        .padding(.trailing, 2)
        .padding(.bottom, 3)  // room for the shadows
    }

    private func section<Content: View>(_ title: String, badge: MenuBadge? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .black, design: .rounded))
                    .kerning(1.3)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let badge { Badge(badge: badge) }
            }
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
        .bubbleCard()
        .padding(.trailing, 2)
    }
}

private struct MenuSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct Badge: View {
    let badge: MenuBadge

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: badge.symbol).font(.system(size: 9, weight: .black))
            Text(badge.title.uppercased()).font(.system(size: 10, weight: .black, design: .rounded)).kerning(1)
        }
        .foregroundStyle(Bubble.ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .bubbleCard(fill: fill, radius: 5, lift: 2)
        .padding(.trailing, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.title)
    }

    private var fill: Color {
        switch badge.tone {
        case .plain: .white
        case .good: Bubble.green
        case .caution: Bubble.yellow
        case .alert: Bubble.orange
        }
    }
}

/// A row with a switch. A click anywhere on it flips the switch, as in the old menu.
private struct ToggleRow: View {
    let model: MenuModel
    let toggle: MenuToggle
    let title: String

    var body: some View {
        let isOn = model.binding(toggle)
        let isEnabled = !model.isDisabled.contains(toggle)
        let id = "\(toggle)"
        HStack(spacing: 12) {
            Text(title)
                .font(Bubble.body(13))
                .foregroundStyle(Bubble.ink.opacity(isEnabled ? 1 : 0.35))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            BubbleSwitch(isOn: isOn.wrappedValue)
                .disabled(!isEnabled)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(minHeight: 36)
        .background(model.hovered == id && isEnabled ? Bubble.hover : Color.white)
        .rowDivider()
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { isOn.wrappedValue.toggle() } }
        .onHover { model.hover(id, $0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { if isEnabled { isOn.wrappedValue.toggle() } }
    }
}

/// The options under a switch, side by side
private struct OptionStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Bubble.tint)
        .rowDivider()
    }
}

/// An option as a pill that turns green with a check when on, like the battle plan app's Going button
private struct OptionChip: View {
    let model: MenuModel
    let toggle: MenuToggle
    let title: String
    /// What it does, for the tooltip
    let help: String

    var body: some View {
        let isOn = model.binding(toggle)
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(BubbleButtonStyle(fill: isOn.wrappedValue ? Bubble.green : .white, height: 24, fontSize: 12))
        .disabled(model.isDisabled.contains(toggle))
        .help(help)
        .accessibilityValue(isOn.wrappedValue ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Allow… as a yellow pill, or a note when there's nothing to press
private struct ActionRow: View {
    let model: MenuModel
    let action: MenuAction

    var body: some View {
        HStack(spacing: 8) {
            if let command = action.command {
                Spacer(minLength: 0)
                Button(action.title) { model.onCommand(command) }
                    .buttonStyle(BubbleButtonStyle(fill: Bubble.yellow, height: 24, fontSize: 12))
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Bubble.orange)
                Text(action.title)
                    .font(Bubble.body(12))
                    .foregroundStyle(Bubble.ink.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Bubble.tint)
        .rowDivider()
    }
}

/// What Stay Awake is doing now, which the menu bar icon shows too, with Finish Setup… or the like beside it
private struct StatusRow: View {
    let model: MenuModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.stayAwakeBadge.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 16)
                Text(model.stayAwakeSummary)
                    .font(Bubble.body(12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let action = model.stayAwakeAction, let command = action.command {
                Button(action.title) { model.onCommand(command) }
                    .buttonStyle(BubbleButtonStyle(fill: command == .retryRestore ? Bubble.orange : Bubble.yellow,
                                                   height: 24, fontSize: 12))
                    .fixedSize()
            }
        }
        .foregroundStyle(Bubble.ink)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(minHeight: 36)
        .background(Bubble.tint)
        .rowDivider()
    }
}

/// A chunky tile that opens one of the tools
private struct ToolTile: View {
    let title: String
    let symbol: String
    let chip: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Bubble.ink)
                    .frame(width: 26, height: 26)
                    .bubbleCard(fill: chip, radius: 7, lift: 0)
                Text(title)
                    .font(Bubble.body(11.5))
                    .foregroundStyle(Bubble.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(TileButtonStyle())
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Bubble.radius, style: .continuous)
        let lift: CGFloat = configuration.isPressed ? 0 : 3
        configuration.label
            .background(shape.fill(configuration.isPressed ? Bubble.tint : Color.white))
            .overlay(shape.strokeBorder(Bubble.ink, lineWidth: Bubble.outline))
            .contentShape(shape)
            .offset(x: (3 - lift) * 0.6, y: 3 - lift)
            .background(shape.fill(Bubble.ink).offset(x: 1.8, y: 3))
    }
}
