import AppKit
import SwiftUI

/// The open editors. While any is open, Yafie is a regular app, with a Dock icon, ⌘Tab and a menu bar.
@MainActor
final class SnipEditors: NSObject {
    private var editors: [SnipEditorController] = []
    /// Gets the focus back when the last editor closes
    private var previousApp: NSRunningApplication?

    var isOpen: Bool { !editors.isEmpty }
    /// Editors with shapes that would be lost
    var unsaved: Int { editors.filter { $0.model.hasUnsavedShapes }.count }

    func open(_ snip: Snip, returningTo app: NSRunningApplication?) {
        if editors.isEmpty {
            previousApp = app
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = SnipMenu.make(editors: self)
        }
        let editor = SnipEditorController(snip: snip, near: NSEvent.mouseLocation)
        editor.onClose = { [weak self, weak editor] in
            if let editor { self?.closed(editor) }
        }
        if let last = editors.last {
            editor.window.setFrameTopLeftPoint(NSPoint(x: last.window.frame.minX + 24, y: last.window.frame.maxY - 24))
        }
        editors.append(editor)
        NSApp.activateRegardless()
        editor.window.makeKeyAndOrderFront(nil)
        // On top even if macOS kept another app active, so a click brings it the rest of the way
        editor.window.orderFrontRegardless()
        snipLogger.notice("Opened a snip in the editor")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if !NSApp.isActive { snipLogger.error("macOS kept Yafie in the background") }
        }
    }

    /// ⌘Q in an editor closes the editors, each asking about unsaved shapes, and leaves Yafie in the menu bar.
    /// Quitting Yafie would also stop Stay Awake and window snapping.
    @objc func quitEditors(_ sender: Any?) {
        for editor in editors { editor.window.performClose(nil) }
    }

    /// Yafie's Dock icon, clicked
    func bringForward() {
        NSApp.activateRegardless()
        editors.last?.window.makeKeyAndOrderFront(nil)
    }

    private func closed(_ editor: SnipEditorController) {
        editors.removeAll { $0 === editor }
        guard editors.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = nil
        NSApp.handFocus(back: previousApp)
        previousApp = nil
    }
}

/// The menu bar while an editor is open. Its items carry every shortcut.
@MainActor
enum SnipMenu {
    /// The single-key shortcuts, like R for Box, are only there while an editor has the keyboard and no text is being
    /// typed. A menu item takes its key even while it's disabled, so otherwise typing r in a text, or in a Save
    /// dialog's name, would do nothing.
    static func setSingleKeys(_ on: Bool) {
        for item in NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? [] {
            guard let key = item.representedObject as? String else { continue }
            item.keyEquivalent = on ? key : ""
        }
    }

    /// - Parameter editors: what ⌘Q closes. Without them, as for a Save dialog from a snip's menu, ⌘Q does nothing.
    static func make(editors: SnipEditors? = nil) -> NSMenu {
        let bar = NSMenu()
        let quitEditors = item("Quit Snip Editor", #selector(SnipEditors.quitEditors(_:)), "q")
        quitEditors.target = editors
        add(Yafie.name, to: bar, [
            item("About \(Yafie.name)", #selector(AppDelegate.showAbout)),
            .separator(),
            item("Hide \(Yafie.name)", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            quitEditors,
            item("Quit \(Yafie.name)", #selector(NSApplication.terminate(_:))),  // no ⌘Q: that closes the editors
        ])
        add("File", to: bar, [
            item("Save…", #selector(SnipEditorController.saveSnip(_:)), "s"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        // Cut, Copy, Paste and Select All are the standard ones, so text fields get them too. Copy copies the snip when
        // an editor has the keyboard.
        add("Edit", to: bar, [
            item("Undo", #selector(SnipEditorController.undoShape(_:)), "z"),
            item("Redo", #selector(SnipEditorController.redoShape(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let tools = SnipTool.allCases.enumerated().map { index, tool in
            singleKey(tool.name, #selector(SnipEditorController.chooseTool(_:)), tool.key, tag: index)
        }
        let colors = Annotation.Color.allCases.enumerated().map { index, color in
            singleKey(color.name, #selector(SnipEditorController.chooseColor(_:)), color.key, tag: index)
        }
        add("Tools", to: bar, tools + [.separator()] + colors + [
            .separator(),
            singleKey("Thick", #selector(SnipEditorController.toggleThickness(_:)), "w"),
        ])
        let window = add("Window", to: bar, [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = window
        return bar
    }

    @discardableResult
    private static func add(_ title: String, to bar: NSMenu, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        for item in items { menu.addItem(item) }
        bar.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    /// Sent along the responder chain, to whatever window has the keyboard
    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    /// Its key is held back until setSingleKeys turns it on
    private static func singleKey(_ title: String, _ action: Selector, _ key: String, tag: Int = 0) -> NSMenuItem {
        let item = item(title, action, "", [], tag: tag)
        item.representedObject = key
        return item
    }
}

/// One snip's editor window
@MainActor
final class SnipEditorController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    let model: SnipEditorModel
    let window: NSWindow
    var onClose: (() -> Void)?

    /// Centered on the display with that point, at the snip's actual size if it fits
    init(snip: Snip, near point: NSPoint) {
        model = SnipEditorModel(snip: snip)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let size = SnipEditorLayout.contentSize(for: snip.size, on: visible)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                              defer: true)
        // The rest of the window is its title bar. Running the content up under it keeps the content's size, which
        // would take the title bar off the window's height, so the content gets that back.
        let titleBar = window.frame.height - size.height
        window.useBubbleChrome()
        window.setContentSize(NSSize(width: size.width, height: size.height + titleBar))
        self.window = window
        super.init()
        let content = NSHostingView(rootView: SnipEditorView(model: model, titleBar: titleBar,
                                                             copy: { [weak self] in self?.copy(nil) },
                                                             save: { [weak self] in self?.saveSnip(nil) }))
        // The window decides its size, down to the sidebar's height
        content.sizingOptions = []
        window.contentView = content
        window.minSize = NSSize(width: SnipEditorLayout.minimumWidth, height: SnipEditorLayout.minimumHeight + titleBar)
        window.title = snip.name
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.setFrameOrigin(NSPoint(x: (visible.midX - window.frame.width / 2).rounded(),
                                      y: (visible.midY - window.frame.height / 2).rounded()))
        observeChanges()
    }

    // MARK: Menu bar actions

    @objc func copy(_ sender: Any?) {
        model.commitText()
        guard let image = model.rendered(), SnipOutput.copy(image, scale: model.snip.scale) else { return NSSound.beep() }
        model.kept()
        snipLogger.notice("Copied the snip from the editor")
    }

    @objc func saveSnip(_ sender: Any?) {
        model.commitText()
        guard let image = model.rendered() else { return NSSound.beep() }
        SnipOutput.save(image, scale: model.snip.scale, name: model.snip.name, from: window) { [weak self] saved in
            guard saved, let self else { return }
            model.kept()
            window.close()
        }
    }

    @objc func undoShape(_ sender: Any?) { model.undo() }
    @objc func redoShape(_ sender: Any?) { model.redo() }
    @objc func chooseTool(_ sender: NSMenuItem) { model.tool = SnipTool.allCases[sender.tag] }
    @objc func chooseColor(_ sender: NSMenuItem) { model.color = Annotation.Color.allCases[sender.tag] }
    @objc func toggleThickness(_ sender: Any?) { model.thickness = model.thickness == .thin ? .thick : .thin }

    /// Everything here needs this editor to have the keyboard, so nothing acts on a window behind a dialog
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard window.isKeyWindow else { return false }
        switch item.action {
        case #selector(undoShape(_:)): return model.canUndo && !model.isEditingText
        case #selector(redoShape(_:)): return model.canRedo && !model.isEditingText
        case #selector(chooseTool(_:)): item.state = SnipTool.allCases[item.tag] == model.tool ? .on : .off
        case #selector(chooseColor(_:)):
            item.state = Annotation.Color.allCases[item.tag] == model.color ? .on : .off
            return model.tool.hasColor
        case #selector(toggleThickness(_:)):
            item.state = model.thickness == .thick ? .on : .off
            return model.tool.hasThickness
        default: break
        }
        return true
    }

    // MARK: Closing

    /// Shapes that haven't been copied or saved get a chance first
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model.commitText()
        guard model.hasUnsavedShapes else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save this snip?"
        alert.informativeText = "Its shapes will be lost if you don't copy or save it."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        discard.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: saveSnip(nil)
            case .alertThirdButtonReturn: window.close()
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Once the window's done closing, since the list of editors holds the last reference to it
        Task { @MainActor [weak self] in self?.onClose?() }
    }

    func windowDidBecomeKey(_ notification: Notification) { updateSingleKeys() }
    func windowDidResignKey(_ notification: Notification) { SnipMenu.setSingleKeys(false) }

    private func updateSingleKeys() {
        SnipMenu.setSingleKeys(window.isKeyWindow && !model.isEditingText)
    }

    /// The close button's unsaved dot, and the single keys, which stay out of the way of typing
    private func observeChanges() {
        withObservationTracking {
            window.isDocumentEdited = model.hasUnsavedShapes
            updateSingleKeys()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeChanges() }
        }
    }
}

// MARK: Model

/// Where the editor keeps the last tool, color, thickness, outline and text size: UserDefaults, or memory in tests
protocol EditorSettings: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: EditorSettings {}

/// What a drag or click on the snip does: draw a kind of shape, or erase one
enum SnipTool: String, CaseIterable, Sendable {
    case box, line, arrow, highlight, blur, text, eraser

    /// What it draws. The eraser takes shapes away instead.
    var kind: Annotation.Kind? { Annotation.Kind(rawValue: rawValue) }
    var name: String { rawValue.capitalized }

    /// Its single-key shortcut
    var key: String {
        switch self {
        case .box: "r"
        case .line: "l"
        case .arrow: "a"
        case .highlight: "h"
        case .blur: "b"
        case .text: "t"
        case .eraser: "e"
        }
    }

    /// What it draws comes in a color, unless it's a blur
    var hasColor: Bool { kind != nil && self != .blur }
    /// Highlights and blurs are filled, and text has a size
    var hasThickness: Bool { self == .box || self == .line || self == .arrow }
    var hasOutline: Bool { hasThickness || self == .text }
}

/// One snip in the editor: its shapes, with undo and redo, and the tool, color, thickness, outline and text size for
/// the next one
@Observable @MainActor
final class SnipEditorModel {
    /// Shorter drags than this, in points, make no shape, so a click doesn't leave a dot
    static let shortestDrag: CGFloat = 4

    let snip: Snip
    private(set) var shapes: [Annotation] = []
    /// The shape following the pointer, until the drag ends
    private(set) var drawing: Annotation?
    /// The text being typed, until Return, Esc or a click elsewhere
    private(set) var draft: Annotation?
    /// Shapes added or taken away since the last Copy or Save
    private(set) var isChanged = false
    /// The shape the eraser points at, which a click takes away
    private(set) var erasable: Int?
    private var undos: [[Annotation]] = []
    private var redos: [[Annotation]] = []
    /// Where the pointer is on the snip, and how near a shape counts as on it, in pixels
    @ObservationIgnored private var pointer: (pixel: CGPoint, slop: CGFloat)?
    @ObservationIgnored private var blurCache: CGImage??

    // The last ones used, for the next snip too
    var tool: SnipTool {
        didSet {
            // Not the eraser, since the next snip has no shapes to erase
            if tool != .eraser { defaults.set(tool.rawValue, forKey: Keys.tool) }
            commitText()
            aim()
        }
    }
    var thickness: Annotation.Thickness {
        didSet { defaults.set(thickness.rawValue, forKey: Keys.thickness) }
    }
    /// Boxes, lines, arrows and text share an outline. Highlights and blurs have none.
    var outline: Annotation.Outline {
        didSet {
            defaults.set(outline.rawValue, forKey: Keys.outline)
            draft?.outline = outline
        }
    }
    /// In points, one of Annotation.textSizes
    var textSize: CGFloat {
        didSet {
            defaults.set(String(Int(textSize)), forKey: Keys.textSize)
            draft?.textSize = textSize
        }
    }
    /// Boxes, lines, arrows and text share a color. The highlighter has its own, so highlights start yellow. Blurs
    /// have none.
    var color: Annotation.Color {
        get { tool == .highlight ? highlightColor : penColor }
        set {
            if tool == .highlight { highlightColor = newValue } else { penColor = newValue }
            draft?.color = newValue
        }
    }
    private var penColor: Annotation.Color {
        didSet { defaults.set(penColor.rawValue, forKey: Keys.color) }
    }
    private var highlightColor: Annotation.Color {
        didSet { defaults.set(highlightColor.rawValue, forKey: Keys.highlightColor) }
    }

    @ObservationIgnored private let defaults: EditorSettings

    private enum Keys {
        static let tool = "snipTool"
        static let color = "snipColor"
        static let highlightColor = "snipHighlightColor"
        static let thickness = "snipThickness"
        static let outline = "snipOutline"
        static let textSize = "snipTextSize"
    }

    init(snip: Snip, defaults: EditorSettings = UserDefaults.standard) {
        self.snip = snip
        self.defaults = defaults
        tool = defaults.string(forKey: Keys.tool).flatMap(SnipTool.init) ?? .box
        penColor = defaults.string(forKey: Keys.color).flatMap(Annotation.Color.init) ?? .red
        highlightColor = defaults.string(forKey: Keys.highlightColor).flatMap(Annotation.Color.init) ?? .yellow
        thickness = defaults.string(forKey: Keys.thickness).flatMap(Annotation.Thickness.init) ?? .thin
        // White and 16 points, as text was before there was a choice
        outline = defaults.string(forKey: Keys.outline).flatMap(Annotation.Outline.init) ?? .white
        let size = defaults.string(forKey: Keys.textSize).flatMap(Double.init).map { CGFloat($0) }
        textSize = size.flatMap { Annotation.textSizes.contains($0) ? $0 : nil } ?? 16
    }

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }
    /// Shapes that closing would lose
    var hasUnsavedShapes: Bool { isChanged && !shapes.isEmpty }
    var isEditingText: Bool { draft != nil }

    /// In the snip's pixels. Text is placed with beginText instead, and the eraser erases.
    func begin(at pixel: CGPoint) {
        guard let kind = tool.kind, kind != .text else { return }
        drawing = Annotation(kind: kind, color: color, thickness: thickness, start: pixel, end: pixel,
                             outline: tool.hasOutline ? outline : .none)
    }

    /// A new text, its top left at that pixel
    func beginText(at pixel: CGPoint) {
        commitText()
        draft = Annotation(kind: .text, color: color, thickness: thickness, start: pixel, end: pixel,
                           textSize: textSize, outline: outline)
    }

    func updateText(_ text: String) {
        draft?.text = text
    }

    /// The text joins the shapes, unless it's blank
    func commitText() {
        guard var text = draft else { return }
        draft = nil
        text.text = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.text.isEmpty else { return }
        add(text)
    }

    func cancelText() {
        draft = nil
    }

    func move(to pixel: CGPoint, constrained: Bool) {
        guard var shape = drawing else { return }
        shape.end = constrained ? Annotation.constrained(shape.kind, from: shape.start, to: pixel) : pixel
        drawing = shape
    }

    func end() {
        guard let shape = drawing else { return }
        drawing = nil
        guard hypot(shape.end.x - shape.start.x, shape.end.y - shape.start.y) >= Self.shortestDrag * snip.scale
        else { return }
        add(shape)
    }

    private func add(_ shape: Annotation) {
        change(to: shapes + [shape])
    }

    /// The pointer moved on the snip, in its pixels, or off it
    func point(at pixel: CGPoint?, slop: CGFloat) {
        pointer = pixel.map { ($0, slop) }
        aim()
    }

    /// Takes away the shape on top at that pixel, as a step to undo
    func erase(at pixel: CGPoint, slop: CGFloat) {
        guard tool == .eraser, let index = Annotation.topmost(at: pixel, in: shapes, scale: snip.scale, slop: slop)
        else { return }
        var next = shapes
        next.remove(at: index)
        change(to: next)
    }

    /// The eraser points at the shape on top under the pointer
    private func aim() {
        var target: Int?
        if tool == .eraser, let pointer {
            target = Annotation.topmost(at: pointer.pixel, in: shapes, scale: snip.scale, slop: pointer.slop)
        }
        if target != erasable { erasable = target }
    }

    private func change(to next: [Annotation]) {
        undos.append(shapes)
        redos.removeAll()
        shapes = next
        isChanged = true
        aim()
    }

    func undo() {
        guard let previous = undos.popLast() else { return }
        redos.append(shapes)
        shapes = previous
        isChanged = true
        aim()
    }

    func redo() {
        guard let next = redos.popLast() else { return }
        undos.append(shapes)
        shapes = next
        isChanged = true
        aim()
    }

    /// After a Copy or Save
    func kept() { isChanged = false }

    /// The snip blurred all over, for blurs to show, made the first time one needs it
    var blurredSnip: CGImage? {
        if blurCache == nil { blurCache = .some(SnipRenderer.blur(snip.image, scale: snip.scale)) }
        return blurCache ?? nil
    }

    /// The snip with its shapes, at full resolution
    func rendered() -> CGImage? {
        SnipRenderer.render(snip.image, shapes, scale: snip.scale,
                            blurred: shapes.contains { $0.kind == .blur } ? blurredSnip : nil)
    }
}

extension Annotation.Color {
    var name: String { rawValue.capitalized }
    /// Its single-key shortcut, 1 to 6
    var key: String { String((Self.allCases.firstIndex(of: self) ?? 0) + 1) }
}

// MARK: Views

/// The sidebar, then the snip with its shapes, on bubble pop blue that runs up under the title bar. All its state is
/// in the model: the Command Line Tools can't build SwiftUI's @State.
struct SnipEditorView: View {
    let model: SnipEditorModel
    let titleBar: CGFloat
    let copy: () -> Void
    let save: () -> Void

    var body: some View {
        // The window is never shorter than the sidebar
        HStack(alignment: .top, spacing: SnipEditorLayout.margin) {
            SnipSidebar(model: model, copy: copy, save: save)
                .frame(width: SnipEditorLayout.sidebarWidth)
            SnipCanvas(model: model)
        }
        .padding(.top, SnipEditorLayout.topMargin)
        .padding([.horizontal, .bottom], SnipEditorLayout.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Bubble.blue.ignoresSafeArea())
        .overlay(alignment: .top) {
            // The snip's name up in the title bar, in chunky white type
            Text(model.snip.name)
                .font(Bubble.display(14))
                .foregroundStyle(.white)
                .shadow(color: Bubble.ink, radius: 0, x: 1, y: 1.5)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 80)  // clear of the close, minimize and zoom buttons
                .frame(height: titleBar)
                .offset(y: -titleBar)
                .allowsHitTesting(false)
                .accessibilityHidden(true)  // the window's title says it
        }
    }
}

/// The tools, colors and options down the left side, with undo and redo, Copy and Save at the bottom. Options that
/// don't go with the tool fade.
struct SnipSidebar: View {
    let model: SnipEditorModel
    let copy: () -> Void
    let save: () -> Void

    var body: some View {
        let tool = model.tool
        VStack(alignment: .leading, spacing: 12) {
            SidebarSection("Tools") {
                VStack(spacing: 7) {
                    ChoiceGrid([SnipTool.box, .line, .arrow, .highlight, .blur, .text], columns: 3) {
                        ToolButton(tool: $0, model: model)
                    }
                    ToolButton(tool: .eraser, model: model, showsName: true)
                }
            }
            SidebarSection("Color") {
                ChoiceGrid(Annotation.Color.allCases, columns: 3) { Swatch(color: $0, model: model) }
            }
            .disabled(!tool.hasColor)
            SidebarSection("Thickness") {
                ChoiceGrid(Annotation.Thickness.allCases, columns: 2) { thickness in
                    ChoicePill(title: thickness.rawValue.capitalized, isChosen: model.thickness == thickness) {
                        model.thickness = thickness
                    }
                    .help("Thin or thick lines (W)")
                }
            }
            .disabled(!tool.hasThickness)
            SidebarSection("Outline") {
                ChoiceGrid(Annotation.Outline.allCases, columns: 2) { outline in
                    ChoicePill(title: outline.rawValue.capitalized, isChosen: model.outline == outline) {
                        model.outline = outline
                    }
                    .help("An outline around boxes, lines, arrows and text, so they stand out")
                }
            }
            .disabled(!tool.hasOutline)
            SidebarSection("Text Size") {
                ChoiceGrid(Annotation.textSizes, columns: 3) { size in
                    ChoicePill(title: "\(Int(size))", isChosen: model.textSize == size) { model.textSize = size }
                        .help("\(Int(size)) points")
                }
            }
            .disabled(tool != .text)

            Spacer(minLength: 0)
            VStack(spacing: 9) {
                HStack(spacing: 7) {
                    Button { model.undo() } label: { ActionLabel("Undo", symbol: "arrow.uturn.backward") }
                        .buttonStyle(BubbleButtonStyle())
                        .disabled(!model.canUndo)
                        .help("Undo (⌘Z)")
                    Button { model.redo() } label: { ActionLabel("Redo", symbol: "arrow.uturn.forward") }
                        .buttonStyle(BubbleButtonStyle())
                        .disabled(!model.canRedo)
                        .help("Redo (⇧⌘Z)")
                }
                HStack(spacing: 7) {
                    Button(action: copy) { Text("Copy").frame(maxWidth: .infinity) }
                        .buttonStyle(BubbleButtonStyle(height: 30, fontSize: 13))
                        .help("Copy to Clipboard (⌘C)")
                    Button(action: save) { Text("Save…").frame(maxWidth: .infinity) }
                        .buttonStyle(BubbleButtonStyle(fill: Bubble.yellow, height: 30, fontSize: 13))
                        .help("Save (⌘S)")
                }
            }
        }
        // Room for the shadows
        .padding(.trailing, 2)
        .padding(.bottom, 3)
    }
}

/// Controls under a name, small, white, upper case and letter-spaced, like the menu's section names. The name fades
/// with its controls.
private struct SidebarSection<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .black, design: .rounded))
                .kerning(1.3)
                .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.45))
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// A few choices in rows, filling the sidebar's width, each as wide as the others in its row
private struct ChoiceGrid<Item: Hashable, Cell: View>: View {
    let items: [Item]
    let columns: Int
    let cell: (Item) -> Cell

    init(_ items: [Item], columns: Int, @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.items = items
        self.columns = columns
        self.cell = cell
    }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { first in
                HStack(spacing: 7) {
                    ForEach(items[first..<min(first + columns, items.count)], id: \.self) { cell($0) }
                }
            }
        }
    }
}

/// A tool's symbol on a tile, yellow while it's the one in use
private struct ToolButton: View {
    let tool: SnipTool
    let model: SnipEditorModel
    /// Its name too, beside the symbol
    var showsName = false

    var body: some View {
        let isChosen = model.tool == tool
        Button { model.tool = tool } label: {
            HStack(spacing: 6) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 15, weight: .bold))
                if showsName { Text(tool.name) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(BubbleButtonStyle(fill: isChosen ? Bubble.yellow : .white, height: 32, fontSize: 13))
        .help("\(tool.name) (\(tool.key.uppercased()))")
        .accessibilityLabel(tool.name)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

private extension SnipTool {
    var symbol: String {
        switch self {
        case .box: "rectangle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .highlight: "highlighter"
        case .blur: "drop.halffull"
        case .text: "textformat"
        case .eraser: "eraser"
        }
    }
}

/// A color on a chip, with a check while it's the one in use
private struct Swatch: View {
    let color: Annotation.Color
    let model: SnipEditorModel

    var body: some View {
        let isChosen = model.color == color
        Button { model.color = color } label: {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(color.takesWhiteCheck ? Color.white : Bubble.ink)
                .opacity(isChosen ? 1 : 0)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(BubbleButtonStyle(fill: Color(cgColor: color.cgColor), height: 26))
        .help("\(color.name) (\(color.key))")
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

private extension Annotation.Color {
    var takesWhiteCheck: Bool { self == .red || self == .blue || self == .black }
}

/// One of a few choices, as a pill that fills its cell and turns yellow when it's the one chosen
private struct ChoicePill: View {
    let title: String
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(BubbleButtonStyle(fill: isChosen ? Bubble.yellow : .white, height: 24, fontSize: 12))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// A button's name with its symbol before it, filling the button
private struct ActionLabel: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The snip, outlined in ink on a hard shadow, with its shapes over it. Dragging on the snip draws, a click with the
/// Text tool places a text, and a click with the eraser takes away the shape under it.
private struct SnipCanvas: View {
    /// How near a shape a click with the eraser takes it, in points
    static let slop: CGFloat = 4

    let model: SnipEditorModel

    var body: some View {
        let snip = model.snip
        // Read here, so a change redraws
        let shapes = model.shapes + (model.drawing.map { [$0] } ?? [])
        let draft = model.draft
        let tool = model.tool
        let erasable = model.erasable
        let blurred = shapes.contains { $0.kind == .blur } ? model.blurredSnip : nil
        GeometryReader { geometry in
            let fit = SnipFit(snip.pixelSize, scale: snip.scale, in: geometry.size)
            let slop = Self.slop * fit.pixelsPerPoint
            let edge = fit.frame.insetBy(dx: -Bubble.outline, dy: -Bubble.outline)
            ZStack {
                // A hard shadow, then an outline just outside the snip
                Rectangle()
                    .fill(Bubble.ink)
                    .frame(width: edge.width, height: edge.height)
                    .position(x: edge.midX + 1.8, y: edge.midY + 3)
                Rectangle()
                    .fill(Bubble.ink)
                    .frame(width: edge.width, height: edge.height)
                    .position(x: edge.midX, y: edge.midY)
                Image(decorative: snip.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.frame.width, height: fit.frame.height)
                    .position(x: fit.frame.midX, y: fit.frame.midY)
                PointerArea(pointer: Pointer(for: tool))
                    .frame(width: fit.frame.width, height: fit.frame.height)
                    .position(x: fit.frame.midX, y: fit.frame.midY)
                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.translateBy(x: fit.frame.minX, y: fit.frame.minY)
                        cg.scaleBy(x: 1 / fit.pixelsPerPoint, y: 1 / fit.pixelsPerPoint)
                        // Cut off at the snip's edges, as when it's saved
                        cg.clip(to: CGRect(origin: .zero, size: snip.pixelSize))
                        SnipRenderer.draw(shapes, in: cg, scale: snip.scale, blurred: blurred, faded: erasable)
                    }
                }
                .allowsHitTesting(false)
                if let draft {
                    let origin = fit.point(for: draft.start)
                    TextEntry(model: model, color: Color(cgColor: draft.color.cgColor),
                              size: draft.textSize * snip.scale / fit.pixelsPerPoint)
                        .frame(width: max(40, fit.frame.maxX - origin.x), alignment: .leading)
                        .padding(.leading, origin.x + TextEntry.offset.x)
                        .padding(.top, origin.y + TextEntry.offset.y)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .id("\(draft.start.x),\(draft.start.y)")  // a new field for each text, so it takes the keyboard
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard tool.kind != nil, tool != .text else { return }
                    if model.drawing == nil {
                        guard fit.frame.contains(drag.startLocation) else { return }
                        model.begin(at: fit.pixel(for: drag.startLocation))
                    }
                    model.move(to: fit.pixel(for: drag.location), constrained: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { drag in
                    let isOnSnip = fit.frame.contains(drag.startLocation)
                    switch tool {
                    case .text:
                        guard isOnSnip else { return model.commitText() }
                        model.beginText(at: fit.pixel(for: drag.startLocation))
                    case .eraser:
                        if isOnSnip { model.erase(at: fit.pixel(for: drag.startLocation), slop: slop) }
                    default:
                        model.end()
                    }
                })
            // So the eraser can show which shape a click would take
            .onContinuousHover { phase in
                if case .active(let location) = phase, fit.frame.contains(location) {
                    model.point(at: fit.pixel(for: location), slop: slop)
                } else {
                    model.point(at: nil, slop: slop)
                }
            }
        }
    }
}

/// Where a text is typed, over the spot where it's drawn. Return places it, Esc drops it, and so does a click
/// elsewhere, which places it.
private struct TextEntry: View {
    /// From the text's top left to the field's, so the letters don't move when the text is placed
    static let offset = CGPoint(x: 0, y: 0)

    let model: SnipEditorModel
    let color: Color
    /// In the canvas's points
    let size: CGFloat
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: Binding(get: { model.draft?.text ?? "" }, set: { model.updateText($0) }))
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(color)
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { model.commitText() }
            .onExitCommand { model.cancelText() }
            .onChange(of: isFocused) { _, focused in
                if !focused { model.commitText() }
            }
    }
}

/// The pointer over the snip: a crosshair to draw, an I-beam for text and an arrow to erase
private enum Pointer {
    case crosshair, iBeam, arrow

    init(for tool: SnipTool) {
        switch tool {
        case .text: self = .iBeam
        case .eraser: self = .arrow
        default: self = .crosshair
        }
    }
}

/// Shows the pointer over the snip. Clicks go through it to the canvas.
private struct PointerArea: NSViewRepresentable {
    let pointer: Pointer

    func makeNSView(context: Context) -> PointerView { PointerView() }

    func updateNSView(_ view: PointerView, context: Context) {
        guard view.pointer != pointer else { return }
        view.pointer = pointer
        view.window?.invalidateCursorRects(for: view)
    }
}

private final class PointerView: NSView {
    var pointer = Pointer.crosshair

    override func resetCursorRects() {
        let cursor: NSCursor = switch pointer {
        case .crosshair: .crosshair
        case .iBeam: .iBeam
        case .arrow: .arrow
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        window?.invalidateCursorRects(for: self)
    }
}
