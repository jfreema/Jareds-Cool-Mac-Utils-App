import AppKit
import Carbon.HIToolbox
import ImageIO
import os

let clipLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "jaredsmacutils", category: "clip")

/// control+option+V brings back the last three things you copied: a picker by the pointer pastes the one you choose,
/// with a click or its number. They're kept in memory only, so they're gone when the app quits or the switch goes off,
/// and anything a password manager marks as private is never kept.
@MainActor
final class ClipboardHistory {
    enum Status { case off, shortcutTaken, on }

    var onChange: (() -> Void)?

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    private(set) var status = Status.off

    private enum Keys {
        static let enabled = "clipboardHistory"
    }

    /// How often it looks for a new copy. macOS doesn't say when the clipboard changes, so every clipboard app looks.
    private static let every: TimeInterval = 0.5

    private var history = ClipHistory()
    private let reader = ClipboardReader()
    private let picker = ClipPicker()
    private var hotKey: HotKey?
    private var timer: Timer?
    /// The clipboard's changeCount at the last look
    private var seenChangeCount = -1
    private var isReading = false
    /// Waiting for a read to finish, like the picker after a copy made a moment before control+option+V
    private var waiting: [@MainActor () -> Void] = []
    private var thumbnails: [UUID: NSImage] = [:]
    /// The app you were in when you pressed control+option+V, which the paste goes to
    private var previousApp: NSRunningApplication?

    func start() {
        picker.onChoose = { [weak self] index in self?.paste(index) }
        refresh()
    }

    /// Pasting presses command+V for you, which needs Accessibility, as window snapping does. Without it, choosing one
    /// only puts it on the clipboard.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled, !AXIsProcessTrusted() {
            // macOS's own dialog, pointing to Privacy & Security → Accessibility. The key is
            // kAXTrustedCheckOptionPrompt's value: Swift 6 won't read that C global.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        refresh()
    }

    /// Matches the shortcut, the watching and the status to the switch. Turning it off forgets what was copied.
    func refresh() {
        let next: Status
        if !isEnabled {
            next = .off
        } else if hotKey == nil, !register() {
            next = .shortcutTaken
        } else {
            next = .on
        }
        if next == .on {
            watch()
        } else {
            stopWatching()
            unregister()
            picker.close()
            history = ClipHistory()
            thumbnails = [:]
        }
        guard next != status else { return }
        status = next
        clipLogger.notice("Clipboard history: \(String(describing: next), privacy: .public)")
        onChange?()
    }

    private func register() -> Bool {
        hotKey = HotKeys.register(kVK_ANSI_V, controlKey | optionKey) { [weak self] in self?.pressed() }
        if hotKey == nil { clipLogger.error("Another app is using ⌃⌥V") }
        return hotKey != nil
    }

    private func unregister() {
        if let hotKey { HotKeys.unregister(hotKey) }
        hotKey = nil
    }

    // MARK: Watching

    private func watch() {
        guard timer == nil else { return }
        // What's on the clipboard now is the first
        seenChangeCount = -1
        check()
        let timer = Timer(timeInterval: Self.every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)  // looks while a menu is open too
        self.timer = timer
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        waiting = []
    }

    /// Reads the clipboard if it changed since the last look, then calls done. The app that copied can take a moment
    /// to hand it over, so it's read on a queue of its own: the main thread runs lid sleep.
    private func check(then done: (@MainActor () -> Void)? = nil) {
        if let done { waiting.append(done) }
        guard !isReading else { return }
        let changeCount = NSPasteboard.general.changeCount
        guard changeCount != seenChangeCount else {
            let work = waiting
            waiting = []
            for done in work { done() }
            return
        }
        seenChangeCount = changeCount
        isReading = true
        reader.read { [weak self] entry in
            guard let self else { return }
            isReading = false
            guard timer != nil else { return }  // turned off meanwhile
            if let entry {
                history.add(entry)
                clipLogger.debug("Kept a copy: \(entry.preview.kind, privacy: .public)")
            }
            // In case it changed again while it was read
            check()
        }
    }

    // MARK: Picking

    private func pressed() {
        clipLogger.debug("control+option+V, picker open: \(self.picker.isOpen), app active: \(NSApp.isActive)")
        if picker.isOpen { return picker.close() }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let point = NSEvent.mouseLocation
        // A copy made since the last look comes first
        check { [weak self] in self?.showPicker(at: point) }
    }

    private func showPicker(at point: NSPoint) {
        guard status == .on else { return }
        guard !history.entries.isEmpty else {
            Toast.show("Nothing copied yet", near: point)
            return
        }
        let ids = Set(history.entries.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }
        let rows = history.entries.enumerated().map { index, entry in
            ClipPickerModel.Row(id: entry.id, number: index + 1, preview: entry.preview,
                                thumbnail: thumbnail(of: entry))
        }
        picker.show(rows, at: point)
    }

    private func thumbnail(of entry: ClipEntry) -> NSImage? {
        guard case .picture = entry.preview else { return nil }
        if let thumbnail = thumbnails[entry.id] { return thumbnail }
        guard let data = entry.pictureData, let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: ClipPickerView.thumbnailPixels]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: .zero)
        thumbnails[entry.id] = thumbnail
        return thumbnail
    }

    // MARK: Pasting

    /// Puts it on the clipboard, then presses command+V in the app you were in. It becomes the newest copy.
    private func paste(_ index: Int) {
        picker.close()
        guard history.entries.indices.contains(index) else { return }
        let entry = history.entries[index]
        let pasteboard = NSPasteboard.general
        // The newest is often still there, with types too big to keep
        if pasteboard.changeCount != entry.changeCount {
            pasteboard.clearContents()
            pasteboard.writeObjects(entry.items.map { types in
                let item = NSPasteboardItem()
                for type in types { item.setData(type.data, forType: NSPasteboard.PasteboardType(type.type)) }
                return item
            })
        }
        seenChangeCount = pasteboard.changeCount
        history.promote(index, changeCount: seenChangeCount)
        guard AXIsProcessTrusted() else {
            clipLogger.notice("Copied number \(index + 1), without Accessibility to paste it")
            Toast.show("Copied: press command+V to paste", near: NSEvent.mouseLocation)
            return
        }
        clipLogger.notice("Pasting number \(index + 1)")
        clipLogger.debug("App active: \(NSApp.isActive), in front: \(Self.frontmost, privacy: .public)")
        let app = previousApp
        Task { @MainActor in
            if await Self.waitToPaste(into: app) {
                Self.pressCommandV()
            } else {
                clipLogger.notice("Couldn't give the keyboard back to paste")
                Toast.show("Copied: press command+V to paste", near: NSEvent.mouseLocation)
            }
        }
    }

    /// Until you've let go of control and option, so the app sees command+V alone, and the app you were in is in front
    /// again, two seconds at most. False if it's still this app in front, where command+V would go nowhere.
    private static func waitToPaste(into app: NSRunningApplication?) async -> Bool {
        var handedBack = false
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if let app, NSApp.isActive, !handedBack {
                NSApp.handFocus(back: app)
                handedBack = true
            }
            let held = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift])
            let isBack = app.map {
                !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == $0.processIdentifier
            }
            if held.isEmpty, isBack ?? true { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // For the app's window to have the keyboard again
        try? await Task.sleep(for: .milliseconds(40))
        clipLogger.debug("Ready to paste, app active: \(NSApp.isActive), in front: \(Self.frontmost, privacy: .public)")
        return app == nil || !NSApp.isActive
    }

    private static var frontmost: String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "nothing" }

    /// As Maccy and other clipboard apps do. The left command key's own flag too, which some apps look for.
    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keys still held down don't mix in
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x8)  // NX_DEVICELCMDKEYMASK
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cgSessionEventTap)
        }
    }
}

/// Reads the clipboard on a queue of its own
final class ClipboardReader: Sendable {
    private let queue = DispatchQueue(label: "jaredsmacutils.clipboard")

    func read(then done: @escaping @MainActor (ClipEntry?) -> Void) {
        queue.async {
            let entry = Self.entry(from: NSPasteboard.general)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(entry) } }
        }
    }

    /// Every type of every item, so pasting it again gives an app all it had, like a spreadsheet's cells. Nothing is
    /// read from a private copy.
    private static func entry(from pasteboard: NSPasteboard) -> ClipEntry? {
        let changeCount = pasteboard.changeCount
        guard let items = pasteboard.pasteboardItems, !items.isEmpty,
              !ClipEntry.isPrivate(items.flatMap { $0.types.map(\.rawValue) }) else { return nil }
        let read = items.map { item in
            item.types.compactMap { type -> ClipData? in
                guard let data = item.data(forType: type), data.count <= ClipEntry.largest else { return nil }
                return ClipData(type: type.rawValue, data: data)
            }
        }
        return ClipEntry(items: read, changeCount: changeCount)
    }
}

// MARK: Pure

/// One type's data on one of the clipboard's items, like public.utf8-plain-text
struct ClipData: Equatable, Sendable {
    let type: String
    let data: Data
}

/// What the picker shows for a copy
enum ClipPreview: Equatable, Sendable {
    /// Its text on one line, cut short
    case text(String)
    /// A picture's size in pixels. The picker draws a thumbnail of it.
    case picture(width: Int, height: Int)
    /// Files copied in Finder, by name
    case files([String])
    /// Something with no text, picture or file, like a color
    case other

    /// For the log, which never shows what was copied
    var kind: String {
        switch self {
        case .text: "text"
        case .picture: "picture"
        case .files: "files"
        case .other: "other"
        }
    }

    static let longest = 300
}

/// Something copied: every item on the clipboard, with all its types
struct ClipEntry: Sendable {
    let id = UUID()
    let items: [[ClipData]]
    let preview: ClipPreview
    /// The clipboard's changeCount when it was read. While the clipboard keeps it, this is still what's on it.
    var changeCount: Int

    /// A type bigger than this isn't kept, like a huge uncompressed picture
    static let largest = 64 << 20

    /// Types that password managers and the like add to say a copy is private or fleeting, from nspasteboard.org
    static let privateTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type", "net.antelle.keeweb",
    ]
    static let textType = "public.utf8-plain-text"
    static let fileType = "public.file-url"
    static let linkType = "public.url"
    static let pictureTypes = ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic"]

    /// Nil for a private copy, or one with nothing kept
    init?(items: [[ClipData]], changeCount: Int) {
        let items = items.filter { !$0.isEmpty }
        guard !items.isEmpty, !Self.isPrivate(items.flatMap { $0.map(\.type) }) else { return nil }
        self.items = items
        self.changeCount = changeCount
        preview = Self.preview(of: items)
    }

    static func isPrivate(_ types: [String]) -> Bool {
        types.contains { privateTypes.contains($0) }
    }

    /// Copied again, it moves to the top instead of showing twice
    func hasSameContent(as other: ClipEntry) -> Bool { items == other.items }

    var pictureData: Data? { Self.pictureData(in: items) }

    /// The first picture, in the first of pictureTypes that has one
    static func pictureData(in items: [[ClipData]]) -> Data? {
        let all = items.flatMap { $0 }
        for type in pictureTypes {
            if let data = all.first(where: { $0.type == type })?.data { return data }
        }
        return nil
    }

    /// Files first, as Finder adds their names as text too. Then text, since apps like Excel and Pages add a picture
    /// of the text. Then a picture, then a link.
    static func preview(of items: [[ClipData]]) -> ClipPreview {
        let all = items.flatMap { $0 }
        func strings(_ type: String) -> [String] {
            all.filter { $0.type == type }.compactMap { String(data: $0.data, encoding: .utf8) }
        }
        let files = strings(fileType).compactMap { URL(string: $0)?.lastPathComponent }.filter { !$0.isEmpty }
        if !files.isEmpty { return .files(files) }
        if let text = strings(textType).map(oneLine).first(where: { !$0.isEmpty }) { return .text(text) }
        if let data = pictureData(in: items) {
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                return .picture(width: width, height: height)
            }
            return .picture(width: 0, height: 0)
        }
        if let link = strings(linkType).map(oneLine).first(where: { !$0.isEmpty }) { return .text(link) }
        return .other
    }

    /// Runs of spaces and line breaks as one space, cut to 300 characters. The picker cuts it to two lines.
    static func oneLine(_ text: String) -> String {
        let start = text.prefix(ClipPreview.longest * 8)
        let words = start.split(whereSeparator: \.isWhitespace)
        let line = words.joined(separator: " ")
        return line.count > ClipPreview.longest ? String(line.prefix(ClipPreview.longest - 1)) + "…" : line
    }
}

/// The last three copies, newest first
struct ClipHistory {
    static let size = 3

    private(set) var entries: [ClipEntry] = []

    mutating func add(_ entry: ClipEntry) {
        entries.removeAll { $0.hasSameContent(as: entry) }
        entries.insert(entry, at: 0)
        if entries.count > Self.size { entries.removeLast(entries.count - Self.size) }
    }

    /// Pasted from the picker, so it's on the clipboard again
    mutating func promote(_ index: Int, changeCount: Int) {
        guard entries.indices.contains(index) else { return }
        var entry = entries.remove(at: index)
        entry.changeCount = changeCount
        entries.insert(entry, at: 0)
    }
}

/// What a key does in the picker. By key code, so the number keys work in any layout and with control and option
/// still held.
enum ClipKey: Equatable {
    /// 1, 2 or 3, on the number row or keypad: that one, counting from 0
    case choose(Int)
    /// Return or Enter: the one lit up
    case chooseLit
    case up, down
    /// Esc or any other key
    case close

    init(keyCode: UInt16) {
        self = switch Int(keyCode) {
        case kVK_ANSI_1, kVK_ANSI_Keypad1: .choose(0)
        case kVK_ANSI_2, kVK_ANSI_Keypad2: .choose(1)
        case kVK_ANSI_3, kVK_ANSI_Keypad3: .choose(2)
        case kVK_Return, kVK_ANSI_KeypadEnter: .chooseLit
        case kVK_UpArrow: .up
        case kVK_DownArrow: .down
        default: .close
        }
    }
}
