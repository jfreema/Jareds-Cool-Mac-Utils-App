import AppKit
import Carbon.HIToolbox
import os
import UniformTypeIdentifiers

let snipLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "yafie", category: "snip")

/// ⌃⌥P snips part of the screen with macOS's own selection, then offers to copy, edit or save it. With its option on,
/// ⌃⌥R records part of the screen as a GIF.
@MainActor
final class ScreenSnipper: NSObject {
    enum Status: Equatable {
        case off, needsPermission, on
        /// Which shortcut, like "control+option+P"
        case shortcutTaken(String)
    }

    var onChange: (() -> Void)?
    let editors = SnipEditors()
    let recorder = ScreenRecorder()

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }
    private(set) var recordsGIFs = UserDefaults.standard.bool(forKey: Keys.recordGIFs) {
        didSet { UserDefaults.standard.set(recordsGIFs, forKey: Keys.recordGIFs) }
    }
    private(set) var status = Status.off

    private enum Keys {
        static let enabled = "snipScreen"
        static let recordGIFs = "recordGIFs"
    }
    private enum Choice: Int { case copy, copyText, edit, save }

    private static let screenRecordingSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    private var hotKey: HotKey?
    private var recordHotKey: HotKey?
    private var capture: SnipCapture?
    /// The snip in the open menu
    private var offered: Snip?
    /// The app you were in when you pressed ⌃⌥P, which gets the focus back
    private var previousApp: NSRunningApplication?

    func start() { refresh() }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        // macOS's own dialog, pointing to Privacy & Security → Screen & System Audio Recording. It shows once per app.
        if enabled, !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        refresh()
    }

    func setRecordsGIFs(_ on: Bool) {
        recordsGIFs = on
        refresh()
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(Self.screenRecordingSettings)
    }

    /// Matches the shortcut and status to the switch and the permission. A running app keeps its old answer about the
    /// permission until it restarts, which is why macOS offers Quit & Reopen once it's allowed. The shortcut stays
    /// while the permission is missing, so pressing it says why there's no snip instead of doing nothing.
    func refresh() {
        let next: Status
        if !isEnabled {
            next = .off
        } else if hotKey == nil, !register() {
            next = .shortcutTaken("control+option+P")
        } else if recordsGIFs, recordHotKey == nil, !registerRecording() {
            next = .shortcutTaken("control+option+R")
        } else if !CGPreflightScreenCaptureAccess() {
            next = .needsPermission
        } else {
            next = .on
        }
        if next == .off { unregister() }
        if !isEnabled || !recordsGIFs { unregisterRecording() }
        guard next != status else { return }
        status = next
        snipLogger.notice("Screen snipping: \(String(describing: next), privacy: .public)")
        onChange?()
    }

    private func register() -> Bool {
        hotKey = HotKeys.register(kVK_ANSI_P, controlKey | optionKey) { [weak self] in self?.pressed() }
        if hotKey == nil { snipLogger.error("Another app is using ⌃⌥P") }
        return hotKey != nil
    }

    private func unregister() {
        if let hotKey { HotKeys.unregister(hotKey) }
        hotKey = nil
    }

    private func registerRecording() -> Bool {
        recordHotKey = HotKeys.register(kVK_ANSI_R, controlKey | optionKey) { [weak self] in self?.pressedRecord() }
        if recordHotKey == nil { snipLogger.error("Another app is using ⌃⌥R") }
        return recordHotKey != nil
    }

    private func unregisterRecording() {
        if let recordHotKey { HotKeys.unregister(recordHotKey) }
        recordHotKey = nil
    }

    private func pressedRecord() {
        guard CGPreflightScreenCaptureAccess() else { return askForPermission(after: "⌃⌥R") }
        recorder.pressed()
    }

    private func pressed() {
        guard capture == nil, offered == nil else { return }  // one at a time
        guard CGPreflightScreenCaptureAccess() else { return askForPermission(after: "⌃⌥P") }
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let clipboard = NSPasteboard.general.changeCount
        capture = SnipCapture { [weak self] outcome in self?.captured(outcome, clipboard: clipboard) }
    }

    /// Never allowed, taken away, or reset by a new signature, as 1.1.6's Developer ID was
    private func askForPermission(after shortcut: String) {
        refresh()
        snipLogger.notice("\(shortcut, privacy: .public) without Screen Recording")
        let previous = NSWorkspace.shared.frontmostApplication
        if Alert.confirm("Allow Screen Snipping",
                         "Turn on \(Yafie.name) in Privacy & Security → Screen & System Audio Recording, then quit and "
                         + "reopen it. If it's already on there, remove it with − and add it again.",
                         button: "Open System Settings") {
            openScreenRecordingSettings()
        } else {
            NSApp.handFocus(back: previous)
        }
    }

    private func captured(_ outcome: SnipCapture.Outcome, clipboard: Int) {
        capture = nil
        switch outcome {
        case .taken(let snip):
            snipLogger.notice("Took a snip, \(snip.image.width) × \(snip.image.height) pixels")
            offer(snip)
        case .cancelled:
            // Holding ⌃ while selecting is screencapture's shortcut for the clipboard, so there's no file
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != clipboard,
               let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff), let snip = Snip(data: data) {
                snipLogger.notice("Took a snip by way of the clipboard, \(snip.image.width) × \(snip.image.height) pixels")
                offer(snip)
            } else {
                snipLogger.notice("Snip cancelled")
            }
        case .failed(let reason):
            snipLogger.error("Couldn't snip: \(reason, privacy: .public)")
            Alert.show("Couldn't take the snip", reason)
            handBackFocus()
        }
    }

    /// The choices, at the pointer, which is where the selection ended. The snip on top, as a thumbnail.
    private func offer(_ snip: Snip) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let preview = NSMenuItem()
        preview.image = Self.thumbnail(of: snip)
        preview.isEnabled = false
        menu.addItem(preview)
        menu.addItem(.separator())
        for (title, choice) in [("Copy to Clipboard", Choice.copy), ("Copy Text", .copyText),
                                ("Open in Editor", .edit), ("Save…", .save)] {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choice.rawValue
            menu.addItem(item)
        }
        offered = snip
        // Without activating Yafie, so the app you were in keeps the focus
        if !menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) {
            offered = nil
            snipLogger.notice("Snip thrown away")
            handBackFocus()
        }
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let snip = offered, let choice = Choice(rawValue: item.tag) else { return }
        offered = nil
        // Once the menu's tracking has unwound
        Task { @MainActor in act(on: snip, choice) }
    }

    private func act(on snip: Snip, _ choice: Choice) {
        switch choice {
        case .copy:
            if SnipOutput.copy(snip.image, scale: snip.scale) { snipLogger.notice("Copied the snip") }
            handBackFocus()
        case .copyText:
            copyText(of: snip, near: NSEvent.mouseLocation)
            handBackFocus()
        case .edit:
            editors.open(snip, returningTo: previousApp)
            previousApp = nil
        case .save:
            SnipOutput.save(snip.image, scale: snip.scale, name: snip.name, from: nil) { [weak self] _ in
                self?.handBackFocus()
            }
        }
    }

    /// The words in the snip, as plain text with its line breaks. Reading them takes a moment, off the main thread.
    private func copyText(of snip: Snip, near point: NSPoint) {
        let image = snip.image
        Task {
            let text = await Task.detached(priority: .userInitiated) { TextRecognizer.text(in: image) }.value
            guard let text else {
                snipLogger.notice("Found no text in the snip")
                return Toast.show("No text found", near: point)
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            snipLogger.notice("Copied the snip's text, \(text.split(separator: "\n").count) lines")
            Toast.show("Text copied", near: point)
        }
    }

    /// So ⌘V pastes where you were
    private func handBackFocus() {
        if NSApp.isActive, !editors.isOpen { NSApp.handFocus(back: previousApp) }
        previousApp = nil
    }

    /// At most 200 × 120 points
    private static func thumbnail(of snip: Snip) -> NSImage {
        let fit = min(1, 200 / snip.size.width, 120 / snip.size.height)
        let size = NSSize(width: max(1, (snip.size.width * fit).rounded()), height: max(1, (snip.size.height * fit).rounded()))
        return NSImage(cgImage: snip.image, size: size)
    }
}

/// One run of macOS's screenshot tool: the ⌘⇧4 selection, with Space for a window and Esc to cancel. It writes the
/// snip to a file of Yafie's, which is read, then deleted.
@MainActor
final class SnipCapture {
    enum Outcome {
        case taken(Snip)
        case cancelled
        case failed(String)
    }

    /// What runs: macOS's tool, unless a test stands in. The file to write goes last.
    struct Tool {
        var executable: URL
        var arguments: [String]

        /// -i selects, -o leaves the shadow off window snips, -x the sound. Without -r, the PNG records the dpi.
        static let screencapture = Tool(executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                                        arguments: ["-i", "-o", "-x"])
    }

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("yafie-snip-\(UUID().uuidString).png")
    private let process = Process()
    private let done: @MainActor (Outcome) -> Void

    init(_ tool: Tool = .screencapture, done: @escaping @MainActor (Outcome) -> Void) {
        self.done = done
        process.executableURL = tool.executable
        process.arguments = tool.arguments + [file.path]
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
        do {
            try process.run()
        } catch {
            let reason = error.localizedDescription
            Task { @MainActor in done(.failed(reason)) }
        }
    }

    /// No file means you cancelled, so this checks for the file, not the exit status
    private func finish() {
        defer { try? FileManager.default.removeItem(at: file) }
        guard FileManager.default.fileExists(atPath: file.path) else { return done(.cancelled) }
        guard let data = try? Data(contentsOf: file), let snip = Snip(data: data) else {
            return done(.failed("The snip couldn't be read."))
        }
        done(.taken(snip))
    }
}

/// Copying and saving snips, for the menu and the editor, and saving recordings
@MainActor
enum SnipOutput {
    private static let folderKey = "snipFolder"

    /// PNG, plus TIFF for apps that only read that
    @discardableResult
    static func copy(_ image: CGImage, scale: CGFloat) -> Bool {
        guard let png = SnipRenderer.data(image, scale: scale) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = SnipRenderer.data(image, scale: scale, type: .tiff) { pasteboard.setData(tiff, forType: .tiff) }
        return true
    }

    /// A Save dialog: a sheet on the editor's window, or on its own from the menu. Calls back with whether it saved.
    static func save(_ image: CGImage, scale: CGFloat, name: String, from window: NSWindow?,
                     then done: @escaping @MainActor (Bool) -> Void) {
        save(name: name, type: .png, what: "snip", from: window, writing: { url in
            guard let png = SnipRenderer.data(image, scale: scale) else { throw SaveFailure.notPNG }
            try png.write(to: url, options: .atomic)
        }, then: done)
    }

    private enum SaveFailure: LocalizedError {
        case notPNG
        var errorDescription: String? { "It couldn't be made into a PNG." }
    }

    /// A Save dialog for any kind of file, which `write` writes where you chose. Snips and recordings share the folder.
    /// - Parameter what: what it's called in an alert if saving fails, like "snip"
    static func save(name: String, type: UTType, what: String, from window: NSWindow?,
                     writing write: @escaping @MainActor (URL) throws -> Void,
                     then done: @escaping @MainActor (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name + "." + (type.preferredFilenameExtension ?? "")
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        // ⌘C, ⌘V and the like in the name field come from the Edit menu, which Yafie only has while an editor is open
        let borrowed = NSApp.mainMenu == nil ? SnipMenu.make() : nil
        if let borrowed { NSApp.mainMenu = borrowed }
        let finish = { (response: NSApplication.ModalResponse) in
            if let borrowed, NSApp.mainMenu === borrowed { NSApp.mainMenu = nil }
            guard response == .OK, let url = panel.url else { return done(false) }
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: folderKey)
            do {
                try write(url)
            } catch {
                snipLogger.error(
                    "Couldn't save a \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
                Alert.show("Couldn't save the \(what)", error.localizedDescription)
                return done(false)
            }
            snipLogger.notice("Saved a \(what, privacy: .public)")
            done(true)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            NSApp.activateRegardless()
            panel.begin(completionHandler: finish)
        }
    }

    /// Where you last saved one, or the Desktop, where macOS saves screenshots
    private static var folder: URL? {
        if let path = UserDefaults.standard.string(forKey: folderKey), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }
}
