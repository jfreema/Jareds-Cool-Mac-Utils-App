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
    /// The Delete key, as a menu item's key
    static let deleteKey = "\u{8}"

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
        // an editor has the keyboard. Delete, on the Delete key, takes away the selected shape.
        add("Edit", to: bar, [
            item("Undo", #selector(SnipEditorController.undoShape(_:)), "z"),
            item("Redo", #selector(SnipEditorController.redoShape(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            singleKey("Delete", #selector(SnipEditorController.deleteShape(_:)), SnipMenu.deleteKey),
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
    @objc func deleteShape(_ sender: Any?) { model.deleteSelected() }

    /// Everything here needs this editor to have the keyboard, so nothing acts on a window behind a dialog
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard window.isKeyWindow else { return false }
        switch item.action {
        case #selector(undoShape(_:)): return model.canUndo && !model.isEditingText
        case #selector(redoShape(_:)): return model.canRedo && !model.isEditingText
        case #selector(chooseTool(_:)): item.state = SnipTool.allCases[item.tag] == model.tool ? .on : .off
        case #selector(chooseColor(_:)):
            item.state = Annotation.Color.allCases[item.tag] == model.color ? .on : .off
            return model.options.hasColor
        case #selector(toggleThickness(_:)):
            item.state = model.thickness == .thick ? .on : .off
            return model.options.hasThickness
        case #selector(deleteShape(_:)): return model.selected != nil && !model.isEditingText
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

/// Where the editor keeps the last tool, color, opacity, thickness and text size: UserDefaults, or memory in tests
protocol EditorSettings: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: EditorSettings {}

/// What a drag or click on the snip does: draw a kind of shape, or erase one. With any tool but the eraser, a press on
/// a shape picks it up instead.
enum SnipTool: String, CaseIterable, Sendable {
    case box, line, arrow, highlight, blur, text, eraser

    /// The one that draws that kind of shape
    init(_ kind: Annotation.Kind) { self = SnipTool(rawValue: kind.rawValue) ?? .box }

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
}

/// One snip in the editor: its shapes, with undo and redo, the one selected, and the tool, color, opacity, thickness
/// and text size for the next one
@Observable @MainActor
final class SnipEditorModel {
    /// Shorter drags than this, in points, make no shape, so a click doesn't leave a dot
    static let shortestDrag: CGFloat = 4

    /// How near a shape, or one of the selected shape's handles, a press takes it, in the snip's pixels
    struct Reach {
        var shape: CGFloat
        var handle: CGFloat
    }

    let snip: Snip
    private(set) var shapes: [Annotation] = []
    /// The shape following the pointer, until the drag ends
    private(set) var drawing: Annotation?
    /// The text being typed, until Return, Esc or a click elsewhere
    private(set) var draft: Annotation?
    /// Shapes added, changed or taken away since the last Copy or Save
    private(set) var isChanged = false
    /// The shape picked up, with its handles showing, which the options and Delete change
    private(set) var selected: Int?
    /// The shape under the pointer that the eraser would take, or a press pick up, and the selected shape's handle
    /// under it
    private(set) var hovered: Int?
    private(set) var hoveredHandle: Int?
    /// While the selected shape, or one of its handles, is dragged
    private(set) var isGrabbing = false
    /// Where the press on the snip that's held began, in its pixels
    @ObservationIgnored private(set) var pressStart: CGPoint?
    private var undos: [[Annotation]] = []
    private var redos: [[Annotation]] = []
    /// Where the pointer is on the snip, in its pixels, and how near counts
    @ObservationIgnored private var pointer: (pixel: CGPoint, reach: Reach)?
    @ObservationIgnored private var press: Press?
    /// While the opacity slider is held: the shapes as they were, so the whole drag is one step to undo
    @ObservationIgnored private var slideStart: [Annotation]?
    @ObservationIgnored private var blurCache: CGImage??

    /// What the press on the snip that's held does when it moves and when it's let go
    private enum Press {
        case drawing
        case placingText(at: CGPoint)
        case erasing(at: CGPoint, slop: CGFloat)
        /// The selected shape, or one of its handles, from where the press began, and the shapes as they were
        case grabbing(handle: Int?, from: CGPoint, before: [Annotation])
    }

    // The last ones used, for the next snip too
    var tool: SnipTool {
        didSet {
            // Not the eraser, since the next snip has no shapes to erase
            if tool != .eraser { defaults.set(tool.rawValue, forKey: Keys.tool) }
            commitText()
            selected = nil
            aim()
        }
    }
    /// The selected shape's line width, or else the next one's
    var thickness: Annotation.Thickness {
        get { selectedShape.flatMap { SnipTool($0.kind).hasThickness ? $0.thickness : nil } ?? nextThickness }
        set {
            nextThickness = newValue
            restyleSelected { if SnipTool($0.kind).hasThickness { $0.thickness = newValue } }
        }
    }
    /// In points, one of Annotation.textSizes: the selected text's, or else the next one's
    var textSize: CGFloat {
        get { selectedShape.flatMap { $0.kind == .text ? $0.textSize : nil } ?? nextTextSize }
        set {
            nextTextSize = newValue
            draft?.textSize = newValue
            restyleSelected { if $0.kind == .text { $0.textSize = newValue } }
        }
    }
    /// The selected shape's color, or else the next one's. Boxes, lines, arrows and text share a color. The
    /// highlighter has its own, so highlights start yellow. Blurs have none.
    var color: Annotation.Color {
        get {
            if let shape = selectedShape, SnipTool(shape.kind).hasColor { return shape.color }
            return options == .highlight ? highlightColor : penColor
        }
        set {
            if options == .highlight { highlightColor = newValue } else { penColor = newValue }
            draft?.color = newValue
            restyleSelected { if SnipTool($0.kind).hasColor { $0.color = newValue } }
        }
    }
    /// From Annotation.opacities, in steps of 5%: the selected shape's, or else the next one's. It goes with the
    /// color: boxes, lines, arrows and text share one, the highlighter has its own, and blurs have none.
    var opacity: CGFloat {
        get {
            if let shape = selectedShape, SnipTool(shape.kind).hasColor { return shape.opacity }
            return options == .highlight ? highlighterOpacity : penOpacity
        }
        set {
            let value = Annotation.snappedOpacity(newValue)
            if options == .highlight { highlighterOpacity = value } else { penOpacity = value }
            draft?.opacity = value
            restyleSelected { if SnipTool($0.kind).hasColor { $0.opacity = value } }
        }
    }
    private var nextThickness: Annotation.Thickness {
        didSet { defaults.set(nextThickness.rawValue, forKey: Keys.thickness) }
    }
    private var nextTextSize: CGFloat {
        didSet { defaults.set(String(Int(nextTextSize)), forKey: Keys.textSize) }
    }
    private var penColor: Annotation.Color {
        didSet { defaults.set(penColor.rawValue, forKey: Keys.color) }
    }
    private var highlightColor: Annotation.Color {
        didSet { defaults.set(highlightColor.rawValue, forKey: Keys.highlightColor) }
    }
    private var penOpacity: CGFloat {
        didSet { defaults.set(Self.percent(penOpacity), forKey: Keys.opacity) }
    }
    private var highlighterOpacity: CGFloat {
        didSet { defaults.set(Self.percent(highlighterOpacity), forKey: Keys.highlighterOpacity) }
    }

    @ObservationIgnored private let defaults: EditorSettings

    private enum Keys {
        static let tool = "snipTool"
        static let color = "snipColor"
        static let highlightColor = "snipHighlightColor"
        static let thickness = "snipThickness"
        static let textSize = "snipTextSize"
        static let opacity = "snipOpacity"
        static let highlighterOpacity = "snipHighlightOpacity"
    }

    init(snip: Snip, defaults: EditorSettings = UserDefaults.standard) {
        self.snip = snip
        self.defaults = defaults
        tool = defaults.string(forKey: Keys.tool).flatMap(SnipTool.init(rawValue:)) ?? .box
        penColor = defaults.string(forKey: Keys.color).flatMap(Annotation.Color.init) ?? .red
        highlightColor = defaults.string(forKey: Keys.highlightColor).flatMap(Annotation.Color.init) ?? .yellow
        nextThickness = defaults.string(forKey: Keys.thickness).flatMap(Annotation.Thickness.init) ?? .thin
        let size = defaults.string(forKey: Keys.textSize).flatMap(Double.init).map { CGFloat($0) }
        nextTextSize = size.flatMap { Annotation.textSizes.contains($0) ? $0 : nil } ?? 16
        penOpacity = Self.savedOpacity(defaults.string(forKey: Keys.opacity))
        highlighterOpacity = Self.savedOpacity(defaults.string(forKey: Keys.highlighterOpacity))
    }

    /// Opacities are kept in percent
    private static func percent(_ opacity: CGFloat) -> String { String(Int((opacity * 100).rounded())) }

    private static func savedOpacity(_ saved: String?) -> CGFloat {
        saved.flatMap(Double.init).map { Annotation.snappedOpacity(CGFloat($0) / 100) } ?? 1
    }

    var canUndo: Bool { !undos.isEmpty }
    var canRedo: Bool { !redos.isEmpty }
    /// Shapes that closing would lose
    var hasUnsavedShapes: Bool { isChanged && !shapes.isEmpty }
    var isEditingText: Bool { draft != nil }
    /// What the options are for: the selected shape, or else what the tool draws next
    var options: SnipTool { selectedShape.map { SnipTool($0.kind) } ?? tool }
    /// The shape the eraser points at, which a click takes away
    var erasable: Int? { tool == .eraser ? hovered : nil }
    private var selectedShape: Annotation? { selected.map { shapes[$0] } }

    // MARK: Pressing on the snip

    /// A press on the snip, in its pixels. On the selected shape's handle, or on a shape, it picks that up to drag.
    /// Elsewhere on the snip, it starts what the tool does, inside a highlight or a blur too. Off it, it only places
    /// the text being typed.
    func pressDown(at pixel: CGPoint, onSnip: Bool, reach: Reach) {
        // One that never ended
        if pressStart != nil { pressUp() }
        commitText()
        pressStart = pixel
        if tool == .eraser {
            if onSnip { press = .erasing(at: pixel, slop: reach.shape) }
        } else if let selected, let handle = shapes[selected].handle(near: pixel, reach: reach.handle) {
            grab(handle: handle, at: pixel)
        } else if !onSnip {
            selected = nil
        } else if let index = pickUp(at: pixel, slop: reach.shape) {
            selected = index
            grab(handle: nil, at: pixel)
        } else if tool == .text {
            selected = nil
            press = .placingText(at: pixel)
        } else {
            begin(at: pixel)
            press = .drawing
        }
    }

    /// Shift keeps a drawing square or at 45° steps, as it does a resize, and a move straight across or up and down
    func pressMoved(to pixel: CGPoint, constrained: Bool) {
        switch press {
        case .drawing:
            move(to: pixel, constrained: constrained)
        case .grabbing(let handle, let from, let before):
            guard let selected else { return }
            var next = before
            if let handle {
                // As far as the pointer went, so a press a little off the handle doesn't make it jump
                let at = before[selected].handles[handle]
                let to = CGPoint(x: at.x + pixel.x - from.x, y: at.y + pixel.y - from.y)
                next[selected] = before[selected].resized(handle: handle, to: to, constrained: constrained)
            } else {
                var offset = CGSize(width: pixel.x - from.x, height: pixel.y - from.y)
                if constrained {
                    if abs(offset.width) < abs(offset.height) { offset.width = 0 } else { offset.height = 0 }
                }
                next[selected] = before[selected].moved(by: offset)
            }
            if next != shapes { shapes = next }
        default:
            break
        }
    }

    /// The press let go: a drawing ends, a click places a text or erases, and a drag of a shape is a step to undo
    func pressUp() {
        let ended = press
        press = nil
        pressStart = nil
        switch ended {
        case .drawing:
            end()
        case .placingText(let pixel):
            beginText(at: pixel)
        case .erasing(let pixel, let slop):
            erase(at: pixel, slop: slop)
        case .grabbing(_, _, let before):
            isGrabbing = false
            if shapes != before { record(before) }
        case nil:
            break
        }
        aim()
    }

    private func grab(handle: Int?, at pixel: CGPoint) {
        press = .grabbing(handle: handle, from: pixel, before: shapes)
        isGrabbing = true
    }

    /// The shape a press there picks up: the one on top, though a highlight or a blur only by its edges, unless it's
    /// the selected one, so a drag inside one draws on it
    private func pickUp(at pixel: CGPoint, slop: CGFloat) -> Int? {
        SnipRenderer.drawingOrder(shapes).last {
            shapes[$0].isHit(by: pixel, scale: snip.scale, slop: slop, edgesOnly: $0 != selected)
        }
    }

    /// The pointer moved on the snip, in its pixels, or off it
    func point(at pixel: CGPoint?, reach: Reach) {
        pointer = pixel.map { ($0, reach) }
        aim()
    }

    /// What's under the pointer: the shape the eraser would take, or else the one a press would pick up, and the
    /// selected shape's handle. Not while a press is held.
    private func aim() {
        var shape: Int?
        var handle: Int?
        if let pointer, press == nil {
            if tool == .eraser {
                shape = Annotation.topmost(at: pointer.pixel, in: shapes, scale: snip.scale, slop: pointer.reach.shape)
            } else {
                shape = pickUp(at: pointer.pixel, slop: pointer.reach.shape)
                handle = selected.flatMap { shapes[$0].handle(near: pointer.pixel, reach: pointer.reach.handle) }
            }
        }
        if shape != hovered { hovered = shape }
        if handle != hoveredHandle { hoveredHandle = handle }
    }

    // MARK: Drawing and changing shapes

    /// In the snip's pixels. Text is placed with beginText instead, and the eraser erases.
    func begin(at pixel: CGPoint) {
        guard let kind = tool.kind, kind != .text else { return }
        selected = nil
        drawing = Annotation(kind: kind, color: color, thickness: thickness, start: pixel, end: pixel,
                             opacity: tool.hasColor ? opacity : 1)
    }

    /// A new text, its label's top left at that pixel
    func beginText(at pixel: CGPoint) {
        commitText()
        selected = nil
        draft = Annotation(kind: .text, color: color, thickness: thickness, start: pixel, end: pixel,
                           textSize: textSize, opacity: opacity)
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

    /// Takes away the shape on top at that pixel, as a step to undo
    func erase(at pixel: CGPoint, slop: CGFloat) {
        guard tool == .eraser, let index = Annotation.topmost(at: pixel, in: shapes, scale: snip.scale, slop: slop)
        else { return }
        var next = shapes
        next.remove(at: index)
        selected = nil
        change(to: next)
    }

    /// Takes away the selected shape, as a step to undo
    func deleteSelected() {
        guard let selected, !isEditingText else { return }
        var next = shapes
        next.remove(at: selected)
        self.selected = nil
        change(to: next)
    }

    /// The opacity slider, as it's dragged and when it's let go
    func slideOpacity(to value: CGFloat, ended: Bool) {
        if slideStart == nil { slideStart = shapes }
        opacity = value
        guard ended, let before = slideStart else { return }
        slideStart = nil
        if shapes != before { record(before) }
    }

    /// The selected shape with an option changed, as a step to undo, or one step for the whole of a slide
    private func restyleSelected(_ restyle: (inout Annotation) -> Void) {
        guard let selected else { return }
        var next = shapes
        restyle(&next[selected])
        guard next != shapes else { return }
        if slideStart == nil { change(to: next) } else { shapes = next }
    }

    private func change(to next: [Annotation]) {
        record(shapes)
        shapes = next
        aim()
    }

    /// The shapes as they were, to undo to
    private func record(_ before: [Annotation]) {
        undos.append(before)
        redos.removeAll()
        isChanged = true
    }

    func undo() {
        slideStart = nil
        guard let previous = undos.popLast() else { return }
        redos.append(shapes)
        restore(previous)
    }

    func redo() {
        slideStart = nil
        guard let next = redos.popLast() else { return }
        undos.append(shapes)
        restore(next)
    }

    /// From undo or redo. The selection stays if the same shapes are there, as after a move.
    private func restore(_ next: [Annotation]) {
        if next.count != shapes.count { selected = nil }
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

/// The tools, colors and options down the left side, with undo and redo, Copy and Save at the bottom. The options are
/// the selected shape's, or else the next one's, and those that don't go with it fade.
struct SnipSidebar: View {
    let model: SnipEditorModel
    let copy: () -> Void
    let save: () -> Void

    var body: some View {
        let options = model.options
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
            .disabled(!options.hasColor)
            SidebarSection("Opacity", detail: "\(Int((model.opacity * 100).rounded()))%") {
                OpacitySlider(model: model)
            }
            .disabled(!options.hasColor)
            SidebarSection("Thickness") {
                ChoiceGrid(Annotation.Thickness.allCases, columns: 2) { thickness in
                    ChoicePill(title: thickness.rawValue.capitalized, isChosen: model.thickness == thickness) {
                        model.thickness = thickness
                    }
                    .help("Thin or thick lines (W)")
                }
            }
            .disabled(!options.hasThickness)
            SidebarSection("Text Size") {
                ChoiceGrid(Annotation.textSizes, columns: 3) { size in
                    ChoicePill(title: "\(Int(size))", isChosen: model.textSize == size) { model.textSize = size }
                        .help("\(Int(size)) points")
                }
            }
            .disabled(options != .text)

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
    /// At the other end of the name's line, like a slider's value
    let detail: String?
    let content: Content
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        let font = Font.system(size: 10.5, weight: .black, design: .rounded)
        let ink = Color.white.opacity(isEnabled ? 1 : 0.45)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .font(font)
                    .kerning(1.3)
                    .foregroundStyle(ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(font)
                        .monospacedDigit()
                        .foregroundStyle(ink)
                        .accessibilityHidden(true)  // the control says it
                }
            }
            content
        }
    }
}

/// How much of a shape shows, from faint to solid: a white track that fills with yellow up to an outlined knob. A
/// drag along it, or a click, is one step to undo.
private struct OpacitySlider: View {
    static let knob: CGFloat = 18

    let model: SnipEditorModel
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let range = Annotation.opacities
        let fraction = (model.opacity - range.lowerBound) / (range.upperBound - range.lowerBound)
        let percent = Int((model.opacity * 100).rounded())
        GeometryReader { geometry in
            // Room on the right for the shadows
            let travel = max(geometry.size.width - Self.knob - 2, 1)
            let track = Capsule(style: .continuous)
            ZStack(alignment: .leading) {
                track.fill(Color.white)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Bubble.yellow).frame(width: Self.knob / 2 + travel * fraction)
                    }
                    .clipShape(track)
                    .overlay(track.strokeBorder(Bubble.ink, lineWidth: Bubble.outline))
                    .background(track.fill(Bubble.ink).offset(x: 1.5, y: 2.5))
                    .frame(width: travel + Self.knob, height: 12)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Bubble.ink, lineWidth: Bubble.outline))
                    .background(Circle().fill(Bubble.ink).offset(x: 1.5, y: 2.5))
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(x: travel * fraction)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { slide(to: $0.location.x, travel: travel, ended: false) }
                .onEnded { slide(to: $0.location.x, travel: travel, ended: true) })
        }
        .frame(height: 22)
        .opacity(isEnabled ? 1 : 0.45)
        .help("How much of a shape shows, from faint to solid")
        .accessibilityElement()
        .accessibilityLabel("Opacity")
        .accessibilityValue("\(percent) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.opacity += 0.1
            case .decrement: model.opacity -= 0.1
            @unknown default: break
            }
        }
    }

    private func slide(to x: CGFloat, travel: CGFloat, ended: Bool) {
        guard isEnabled else { return }
        let range = Annotation.opacities
        let fraction = min(max((x - Self.knob / 2) / travel, 0), 1)
        model.slideOpacity(to: range.lowerBound + fraction * (range.upperBound - range.lowerBound), ended: ended)
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
/// Text tool places a text, and a click with the eraser takes away the shape under it. With the other tools, a press
/// on a shape picks it up, to drag it or the handles it then shows.
private struct SnipCanvas: View {
    /// How near a shape a press takes it, and how near one of the selected shape's handles, in points
    static let slop: CGFloat = 4
    static let handleReach: CGFloat = 7

    let model: SnipEditorModel

    var body: some View {
        let snip = model.snip
        // Read here, so a change redraws
        let shapes = model.shapes + (model.drawing.map { [$0] } ?? [])
        let draft = model.draft
        let erasable = model.erasable
        let selection = model.selected.map { model.shapes[$0] }
        let pointer = self.pointer
        let blurred = shapes.contains { $0.kind == .blur } ? model.blurredSnip : nil
        GeometryReader { geometry in
            let fit = SnipFit(snip.pixelSize, scale: snip.scale, in: geometry.size)
            let reach = SnipEditorModel.Reach(shape: Self.slop * fit.pixelsPerPoint,
                                              handle: Self.handleReach * fit.pixelsPerPoint)
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
                PointerArea(pointer: pointer)
                    .frame(width: fit.frame.width, height: fit.frame.height)
                    .position(x: fit.frame.midX, y: fit.frame.midY)
                Canvas { context, _ in
                    context.withCGContext { cg in
                        cg.translateBy(x: fit.frame.minX, y: fit.frame.minY)
                        cg.scaleBy(x: 1 / fit.pixelsPerPoint, y: 1 / fit.pixelsPerPoint)
                        // Cut off at the snip's edges, as when it's saved
                        cg.clip(to: CGRect(origin: .zero, size: snip.pixelSize))
                        SnipRenderer.draw(shapes, in: cg, scale: snip.scale, blurred: blurred, faded: erasable)
                        // The text being typed on its label, under the field's letters
                        if let draft { SnipRenderer.drawLabelBeingTyped(draft, in: cg, scale: snip.scale) }
                    }
                    if let selection { SelectionMarks(shape: selection, fit: fit, scale: snip.scale).draw(in: context) }
                }
                .allowsHitTesting(false)
                if let draft {
                    // Past the room around the letters on the label
                    let padding = Annotation.labelPadding(draft.textSize)
                    let origin = fit.point(for: CGPoint(x: draft.start.x + padding.width * snip.scale,
                                                        y: draft.start.y + padding.height * snip.scale))
                    TextEntry(model: model, color: Color(cgColor: draft.color.labelInk),
                              size: draft.textSize * snip.scale / fit.pixelsPerPoint)
                        .opacity(draft.opacity)
                        .frame(width: max(40, fit.frame.maxX - origin.x), alignment: .leading)
                        .padding(.leading, origin.x)
                        .padding(.top, origin.y)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                        .id("\(draft.start.x),\(draft.start.y)")  // a new field for each text, so it takes the keyboard
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = fit.pixel(for: drag.startLocation)
                    if model.pressStart != start {
                        model.pressDown(at: start, onSnip: fit.frame.contains(drag.startLocation), reach: reach)
                        if model.isGrabbing { NSCursor.closedHand.set() }
                    }
                    model.pressMoved(to: fit.pixel(for: drag.location),
                                     constrained: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { _ in model.pressUp() })
            // So the eraser can show which shape a click would take, and the pointer what a press would pick up
            .onContinuousHover { phase in
                if case .active(let location) = phase, fit.frame.contains(location) {
                    model.point(at: fit.pixel(for: location), reach: reach)
                } else {
                    model.point(at: nil, reach: reach)
                }
            }
        }
    }

    /// A hand over a shape a press would pick up, closed while it's dragged, and a pointing hand on a handle
    private var pointer: Pointer {
        if model.isGrabbing { return .closedHand }
        if model.hoveredHandle != nil { return .pointingHand }
        if model.hovered != nil && model.tool != .eraser { return .openHand }
        return Pointer(for: model.tool)
    }
}

/// The selected shape's handles, white dots outlined in ink, and a dashed line around a highlight, a blur or a text
private struct SelectionMarks {
    let shape: Annotation
    let fit: SnipFit
    let scale: CGFloat

    func draw(in context: GraphicsContext) {
        let frame: CGRect? = switch shape.kind {
        case .highlight, .blur: shape.rect
        case .text: SnipRenderer.labelBounds(shape, scale: scale)
        case .box, .line, .arrow: nil
        }
        if let frame {
            let topLeft = fit.point(for: frame.origin)
            let bottomRight = fit.point(for: CGPoint(x: frame.maxX, y: frame.maxY))
            let around = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x,
                                height: bottomRight.y - topLeft.y).insetBy(dx: -3, dy: -3)
            let line = Path(roundedRect: around, cornerRadius: 4)
            context.stroke(line, with: .color(.white), lineWidth: 1.5)
            context.stroke(line, with: .color(Bubble.ink), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        for handle in shape.handles {
            let center = fit.point(for: handle)
            let dot = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            context.fill(dot, with: .color(.white))
            context.stroke(dot, with: .color(Bubble.ink), lineWidth: 2)
        }
    }
}

/// Where a text is typed, on its label, over the spot where its letters are drawn. Return places it, Esc drops it, and
/// so does a click elsewhere, which places it.
private struct TextEntry: View {
    let model: SnipEditorModel
    /// The letters', white or dark on the label
    let color: Color
    /// In the canvas's points
    let size: CGFloat
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: Binding(get: { model.draft?.text ?? "" }, set: { model.updateText($0) }))
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: .bold, design: .rounded))
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

/// The pointer over the snip: a crosshair to draw, an I-beam for text and an arrow to erase, or a hand for a shape
private enum Pointer {
    case crosshair, iBeam, arrow, openHand, closedHand, pointingHand

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
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .pointingHand: .pointingHand
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        window?.invalidateCursorRects(for: self)
    }
}
