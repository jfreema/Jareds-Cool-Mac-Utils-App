import AppKit
import ImageIO
import SwiftUI

/// The picker's rows, and which one is lit
@Observable @MainActor
final class ClipPickerModel {
    struct Row: Identifiable {
        let id: UUID
        /// 1 is the newest
        let number: Int
        let preview: ClipPreview
        let thumbnail: NSImage?
    }

    var rows: [Row] = []
    /// Under the pointer, or moved with the arrow keys. Return pastes it.
    var lit = 0
    /// Held down by the mouse
    var pressed: Int?
    /// Each row's frame from the top left of the panel, to find the one clicked
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]

    @ObservationIgnored var onChoose: (Int) -> Void = { _ in }
    @ObservationIgnored var onResize: (CGSize) -> Void = { _ in }
}

/// The last three copies by the pointer, in the bubble pop style. Like the menu, it takes the keyboard without
/// activating the app, so the app you're in keeps the focus, and it closes on a click elsewhere or Esc.
@MainActor
final class ClipPicker: NSObject, NSWindowDelegate {
    let model = ClipPickerModel()
    /// With the row's index, counting from 0
    var onChoose: ((Int) -> Void)? {
        didSet { model.onChoose = { [weak self] index in self?.onChoose?(index) } }
    }

    private lazy var panel = makePanel()
    private lazy var content = NSHostingController(rootView: ClipPickerView(model: model))
    private var clickMonitor: Any?
    /// Where the pointer was
    private var anchor = NSPoint.zero
    /// The row the mouse went down on
    private var downRow: Int?
    /// A click that went down on the picker, through the tap, until it comes up
    private var isClicking = false
    private var height: CGFloat = 200

    var isOpen: Bool { panel.isVisible }

    func show(_ rows: [ClipPickerModel.Row], at point: NSPoint) {
        model.rows = rows
        model.lit = 0
        model.pressed = nil
        downRow = nil
        isClicking = false
        anchor = point
        // The panel first, so the rows are in its view when it's measured. A wrong guess is put right by onResize.
        _ = panel
        content.view.layoutSubtreeIfNeeded()
        height = content.sizeThatFits(in: NSSize(width: ClipPickerView.width, height: 2000)).height.rounded(.up)
        place()
        panel.makeKeyAndOrderFront(nil)
        let tapped = ClipClickTap.start { [weak self] type, location in self?.tapped(type, at: location) ?? false }
        clipLogger.debug("Picker shown with \(rows.count) copies, \(Int(self.height)) points tall, tap: \(tapped)")
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
                                                                        .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "Clipboard history: press 1, 2 or 3 to paste",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        ClipClickTap.pause()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        clipLogger.debug("Picker closed")
    }

    func windowDidResignKey(_ notification: Notification) {
        clipLogger.debug("Picker lost the keyboard")
        close()
    }

    /// Hangs from the pointer, like a menu, or stands on it near the bottom of the screen, and stays on its screen
    private func place() {
        let width = ClipPickerView.width
        let area = (NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: anchor.x, y: anchor.y - height, width: width, height: height)
        var y = anchor.y - 4 - height
        if y < area.minY + 6 { y = anchor.y + 4 }
        let x = min(max(anchor.x + 4, area.minX + 6), area.maxX - 6 - width)
        y = min(max(y, area.minY + 6), area.maxY - 6 - height)
        panel.setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height), display: true)
        panel.invalidateShadow()
    }

    private func pressed(_ key: ClipKey) {
        switch key {
        case .choose(let index):
            if model.rows.indices.contains(index) { model.onChoose(index) }
        case .chooseLit:
            if model.rows.indices.contains(model.lit) { model.onChoose(model.lit) }
        case .up:
            model.lit = max(model.lit - 1, 0)
        case .down:
            model.lit = min(model.lit + 1, model.rows.count - 1)
        case .close:
            close()
        }
    }

    /// A click on a panel brings this app to the front, though the panel is non-activating, and then command+V would go
    /// to this app instead of yours. So while the picker is open, an event tap takes clicks on it before they reach any
    /// window, which needs Accessibility, as pasting does. A click anywhere else closes it and goes on.
    private func tapped(_ type: CGEventType, at location: CGPoint) -> Bool {
        guard panel.isVisible, let main = NSScreen.screens.first else { return false }
        let frame = panel.frame
        // From the top left of the main display, to the top left of the panel
        let point = CGPoint(x: location.x - frame.minX, y: location.y - (main.frame.maxY - frame.maxY))
        let inside = CGRect(origin: .zero, size: frame.size).contains(point)
        switch type {
        case .leftMouseDown:
            guard inside else {
                close()
                return false
            }
            isClicking = true
            click(.leftMouseDown, at: point)
            return true
        case .leftMouseDragged, .leftMouseUp:
            guard isClicking else { return false }
            if type == .leftMouseUp { isClicking = false }
            // Once the tap has handed the click back
            Task { @MainActor [weak self] in self?.click(type, at: point) }
            return true
        case .rightMouseDown, .otherMouseDown:
            if !inside { close() }
            return inside
        default:
            return inside
        }
    }

    /// Without the tap, the picker gets its clicks as any window does, and SwiftUI never sees them
    private func mouse(_ event: NSEvent) {
        guard let view = panel.contentView else { return }
        let type: CGEventType = switch event.type {
        case .leftMouseDown: .leftMouseDown
        case .leftMouseDragged: .leftMouseDragged
        default: .leftMouseUp
        }
        click(type, at: CGPoint(x: event.locationInWindow.x, y: view.bounds.height - event.locationInWindow.y))
    }

    /// Like a menu, a row is chosen when the button comes up on the row it went down on. The point is from the top left
    /// of the panel.
    private func click(_ type: CGEventType, at point: CGPoint) {
        let row = model.rowFrames.first { $0.value.contains(point) }?.key
        switch type {
        case .leftMouseDown:
            clipLogger.debug("Click on the picker, app active: \(NSApp.isActive)")
            downRow = row
            model.pressed = row
        case .leftMouseDragged:
            model.pressed = row == downRow ? row : nil
            if let row { model.lit = row }
        case .leftMouseUp:
            let chosen = row != nil && row == downRow ? row : nil
            downRow = nil
            model.pressed = nil
            if let chosen, model.rows.indices.contains(chosen) { model.onChoose(chosen) }
        default:
            break
        }
    }

    private func makePanel() -> NSPanel {
        let panel = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: ClipPickerView.width, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.onKey = { [weak self] keyCode in self?.pressed(ClipKey(keyCode: keyCode)) }
        panel.onMouse = { [weak self] event in self?.mouse(event) }
        content.sizingOptions = []
        panel.contentViewController = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        // Over full-screen apps too, and never in ⌘Tab or Mission Control
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        model.onResize = { [weak self] size in
            guard let self, size.height.rounded(.up) != height else { return }
            height = size.height.rounded(.up)
            if self.panel.isVisible { place() }
        }
        return panel
    }
}

/// Takes clicks on the picker before any window gets them, while it's open. Made once and paused in between, since a
/// tap shouldn't be torn down from its own callback, which is where a click that closes the picker comes from. Its
/// source is on the main run loop: if the main thread hangs, macOS turns the tap off and clicks go through again.
@MainActor
enum ClipClickTap {
    private static var tap: CFMachPort?
    /// With the click's type and where it is from the top left of the main display. True keeps it from the apps.
    private static var handler: ((CGEventType, CGPoint) -> Bool)?

    /// False without Accessibility
    static func start(_ handler: @escaping (CGEventType, CGPoint) -> Bool) -> Bool {
        self.handler = handler
        if tap == nil, AXIsProcessTrusted() {
            let callback: CGEventTapCallBack = { _, type, event, _ in
                let location = event.location
                let taken = MainActor.assumeIsolated { ClipClickTap.received(type, location) }
                return taken ? nil : Unmanaged.passUnretained(event)
            }
            let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                        .otherMouseDown, .otherMouseUp]
            let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1.rawValue) }
            if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback, userInfo: nil) {
                CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
                self.tap = tap
            }
        }
        guard let tap else { return false }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    static func pause() {
        handler = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private static func received(_ type: CGEventType, _ location: CGPoint) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned it off after a hang. The app is answering again.
            if let tap, handler != nil { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        default:
            return handler?(type, location) ?? false
        }
    }
}

/// Takes the keyboard without activating the app: every key and click goes to the picker
private final class ClipPanel: NSPanel {
    var onKey: ((UInt16) -> Void)?
    var onMouse: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            onKey?(event.keyCode)
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            onMouse?(event)
        default:
            super.sendEvent(event)
        }
    }
}

struct ClipPickerView: View {
    static let width: CGFloat = 320
    /// A thumbnail is 96 by 48 points at most, drawn at 2x
    static let thumbnailPixels = 192

    /// A picture's shape, 96 by 48 points at most
    nonisolated static func thumbnailSize(of size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 48, height: 48) }
        let scale = min(96 / size.width, 48 / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    let model: ClipPickerModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 7) {
            Text("CLIPBOARD HISTORY")
                .font(.system(size: 10.5, weight: .black, design: .rounded))
                .kerning(1.3)
                .foregroundStyle(.white)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(model.rows) { row in
                ClipRowButton(model: model, row: row)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ClipRowFramesKey.self,
                                               value: [row.number - 1: geometry.frame(in: .global)])
                    })
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 12)  // room for the shadows
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Bubble.blue)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Bubble.ink, lineWidth: 2.5))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ClipSizeKey.self, value: geometry.size)
        })
        .onPreferenceChange(ClipSizeKey.self) { size in
            MainActor.assumeIsolated { model.onResize(size) }
        }
        .onPreferenceChange(ClipRowFramesKey.self) { frames in
            MainActor.assumeIsolated { model.rowFrames = frames }
        }
    }
}

private struct ClipRowFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ClipSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// A copy as a card with its number, lit under the pointer
private struct ClipRowButton: View {
    let model: ClipPickerModel
    let row: ClipPickerModel.Row

    var body: some View {
        let index = row.number - 1
        // Clicks go to ClipPicker.mouse instead. The button is for VoiceOver.
        Button { model.onChoose(index) } label: {
            HStack(spacing: 9) {
                Text(verbatim: "\(row.number)")
                    .font(Bubble.display(13))
                    .foregroundStyle(Bubble.ink)
                    .frame(width: 22, height: 22)
                    .bubbleCard(fill: chip, radius: 6, lift: 0)
                    .accessibilityHidden(true)
                preview
                Spacer(minLength: 0)
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ClipRowStyle(isLit: model.lit == index, isPressed: model.pressed == index))
        .onHover { inside in if inside { model.lit = index } }
        .padding(.trailing, 2)
        .accessibilityLabel("\(row.number): \(spoken)")
        .accessibilityHint("Pastes it")
    }

    /// Like the menu's tool tiles
    private var chip: Color {
        switch row.number {
        case 1: Bubble.yellow
        case 2: Bubble.green
        default: Bubble.orange
        }
    }

    @ViewBuilder private var preview: some View {
        switch row.preview {
        case .text(let text):
            Text(verbatim: text)
                .font(Bubble.body(12.5))
                .foregroundStyle(Bubble.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        case .picture:
            if let thumbnail = row.thumbnail {
                let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                let size = ClipPickerView.thumbnailSize(of: thumbnail.size)
                Image(nsImage: thumbnail)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Bubble.ink.opacity(0.35), lineWidth: 1))
            }
            note(spoken, symbol: row.thumbnail == nil ? "photo" : nil)
        case .files:
            note(spoken, symbol: "doc.fill")
        case .other:
            note(spoken, symbol: nil).opacity(0.6)
        }
    }

    private func note(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
            }
            Text(verbatim: text)
                .font(Bubble.body(12.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Bubble.ink)
    }

    private var spoken: String {
        switch row.preview {
        case .text(let text): text
        case .picture(let width, let height): width > 0 ? "Picture, \(width) × \(height)" : "Picture"
        case .files(let names): names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        case .other: "Something with no text"
        }
    }
}

private struct ClipRowStyle: ButtonStyle {
    let isLit: Bool
    let isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Bubble.radius, style: .continuous)
        let isPressed = isPressed || configuration.isPressed
        let lift: CGFloat = isPressed ? 0 : 3
        configuration.label
            .background(shape.fill(isPressed ? Bubble.tint : isLit ? Bubble.hover : Color.white))
            .overlay(shape.strokeBorder(Bubble.ink, lineWidth: Bubble.outline))
            .contentShape(shape)
            .offset(x: (3 - lift) * 0.6, y: 3 - lift)
            .background(shape.fill(Bubble.ink).offset(x: 1.8, y: 3))
    }
}

#if DEBUG
/// A picture of the picker with a sample of each kind (--render-clipboard <png file>), to see it without a screen
enum ClipPickerPicture {
    @MainActor static func render(to path: String) -> Bool {
        let model = ClipPickerModel()
        let dots = NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
            NSColor(Bubble.sky).setFill()
            rect.fill()
            NSColor(Bubble.orange).setFill()
            NSBezierPath(ovalIn: NSRect(x: 20, y: 15, width: 70, height: 70)).fill()
            return true
        }
        model.rows = [
            .init(id: UUID(), number: 1, preview: .text("Meet at the north entrance at 7:30, and bring the tickets "
                + "and the folding chairs from the garage"), thumbnail: nil),
            .init(id: UUID(), number: 2, preview: .picture(width: 1600, height: 1000), thumbnail: dots),
            .init(id: UUID(), number: 3, preview: .files(["Battle Plan.pdf"]), thumbnail: nil),
        ]
        let renderer = ImageRenderer(content: ClipPickerView(model: model))
        renderer.proposedSize = ProposedViewSize(width: ClipPickerView.width, height: 1000)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let file = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString,
                                                         1, nil) else { return false }
        CGImageDestinationAddImage(file, image, nil)
        return CGImageDestinationFinalize(file)
    }
}
#endif
