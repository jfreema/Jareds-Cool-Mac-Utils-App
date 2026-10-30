import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// ⌃⌥R records part of the screen as a GIF, to show scrolling through a page or the like: drag across it or click a
/// window, do what you want to show, then stop. The GIF is written as it records, then offered to copy or save.
@MainActor
final class ScreenRecorder: NSObject {
    /// It stops by itself after this many seconds
    static let longest = 60

    private enum Stage {
        case idle
        case picking(RecordingPicker)
        case recording(GIFRecording, RecordingControls)
        /// Starting, stopping, or offering what it recorded
        case busy
    }
    private enum Choice: Int { case copy, save }

    private var stage = Stage.idle
    /// The app you were in, which gets the focus back once you've picked
    private var previousApp: NSRunningApplication?
    /// The recording in the open menu
    private var offered: GIFRecording.Result?

    /// Where recordings wait to be copied or saved. macOS clears out old files there by itself.
    private static var folder: URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Picks what to record, stops recording, or cancels picking
    func pressed() {
        switch stage {
        case .idle: pick()
        case .picking(let picker): picker.cancel()
        case .recording: stop()
        case .busy: break
        }
    }

    private func pick() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        stage = .picking(RecordingPicker { [weak self] pick in self?.picked(pick) })
    }

    private func picked(_ pick: RecordingPicker.Pick?) {
        // So scrolling and typing go to the app you were in
        NSApp.handFocus(back: previousApp)
        previousApp = nil
        guard let pick, let display = pick.screen.displayID else {
            stage = .idle
            return snipLogger.notice("Recording cancelled")
        }
        stage = .busy
        let controls = RecordingControls(around: pick.area, on: pick.screen) { [weak self] in self?.stop() }
        let file = Self.folder.appendingPathComponent(Snip.name("Recording", for: Date()) + ".gif")
        let size = RecordingLayout.gifSize(for: pick.area.size)
        let source = RecordingLayout.displayRect(pick.area, on: pick.screen.frame)
        let onStop: @Sendable (String) -> Void = { [weak self] reason in
            Task { @MainActor in self?.stopped(because: reason) }
        }
        Task {
            do {
                let recording = try await GIFRecording.start(display: display, area: source, size: size, file: file,
                                                             onStop: onStop)
                stage = .recording(recording, controls)
                controls.startClock(stoppingAfter: Self.longest)
                snipLogger.notice("Recording \(size.width) × \(size.height) pixels")
            } catch {
                controls.close()
                stage = .idle
                snipLogger.error("Couldn't record: \(error.localizedDescription, privacy: .public)")
                Alert.show("Couldn't record the screen", error.localizedDescription)
            }
        }
    }

    private func stop() {
        guard case .recording(let recording, let controls) = stage else { return }
        stage = .busy
        controls.close()
        Task {
            let result = await recording.stop()
            guard result.frameCount > 0 else {
                stage = .idle
                try? FileManager.default.removeItem(at: result.file)
                snipLogger.notice("Recorded nothing")
                return Toast.show("Nothing recorded", near: NSEvent.mouseLocation)
            }
            snipLogger.notice("Recorded \(result.frameCount) frames, \(result.seconds) seconds, \(result.bytes) bytes")
            offer(result)
        }
    }

    /// ScreenCaptureKit stopped, as when the display went away or you stopped it from the menu bar
    private func stopped(because reason: String) {
        snipLogger.notice("Recording stopped: \(reason, privacy: .public)")
        stop()
    }

    /// The choices, at the pointer, with the first frame on top, like a snip's
    private func offer(_ result: GIFRecording.Result) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let frame = result.firstFrame {
            let preview = NSMenuItem()
            preview.image = RecordingLayout.thumbnail(of: frame)
            preview.isEnabled = false
            menu.addItem(preview)
        }
        let summary = NSMenuItem(title: RecordingLayout.summary(seconds: result.seconds, bytes: result.bytes),
                                 action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())
        for (title, choice) in [("Copy to Clipboard", Choice.copy), ("Save…", .save)] {
            let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choice.rawValue
            menu.addItem(item)
        }
        offered = result
        // Without activating Yafie, so the app you were in keeps the focus
        if !menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) {
            offered = nil
            stage = .idle
            try? FileManager.default.removeItem(at: result.file)
            snipLogger.notice("Recording thrown away")
        }
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let result = offered, let choice = Choice(rawValue: item.tag) else { return }
        offered = nil
        // Once the menu's tracking has unwound
        Task { @MainActor in act(on: result, choice) }
    }

    private func act(on result: GIFRecording.Result, _ choice: Choice) {
        stage = .idle
        switch choice {
        case .copy:
            Self.copy(result.file)
            snipLogger.notice("Copied a recording")
            Toast.show("GIF copied", near: NSEvent.mouseLocation)
        case .save:
            let frontmost = NSWorkspace.shared.frontmostApplication
            let previous = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
            let name = result.file.deletingPathExtension().lastPathComponent
            SnipOutput.save(name: name, type: .gif, what: "GIF", from: nil, writing: { url in
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.moveItem(at: result.file, to: url)
            }, then: { _ in
                try? FileManager.default.removeItem(at: result.file)
                if NSApp.isActive { NSApp.handFocus(back: previous) }
            })
        }
    }

    /// The file, which apps like Messages, Mail and Slack attach as it is, and the GIF itself, for apps that only
    /// take pictures
    private static func copy(_ file: URL) {
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        if let gif = try? Data(contentsOf: file, options: .mappedIfSafe) {
            item.setData(gif, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}

// MARK: Picking

/// Covers every screen to pick what to record. A drag picks part of a screen, a click the window under the pointer,
/// or the whole screen off any window. Esc cancels.
@MainActor
final class RecordingPicker {
    struct Pick {
        /// In points, from the bottom left of the main screen, as AppKit counts
        var area: CGRect
        var screen: NSScreen
    }

    /// What lights up: the area dragged across, or what a click there would pick
    private(set) var highlight: CGRect?
    private var done: ((Pick?) -> Void)?
    private var windows: [PickerWindow] = []
    /// Other apps' windows, front to back
    private let targets = RecordingPicker.windowFrames()
    private var dragStart: CGPoint?
    private var isDragging = false

    init(done: @escaping (Pick?) -> Void) {
        self.done = done
        for screen in NSScreen.screens {
            let window = PickerWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered,
                                      defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let view = PickerView()
            view.picker = self
            window.contentView = view
            window.makeFirstResponder(view)
            windows.append(window)
        }
        // For the keyboard, so Esc cancels, and for the crosshair
        NSApp.activateRegardless()
        let pointer = NSEvent.mouseLocation
        for window in windows { window.orderFrontRegardless() }
        (windows.first { NSMouseInRect(pointer, $0.frame, false) } ?? windows.first)?.makeKey()
        moved(to: pointer)
    }

    func cancel() { finish(nil) }

    fileprivate func moved(to point: CGPoint) {
        guard !isDragging else { return }
        setHighlight(Self.screen(at: point).map { RecordingLayout.clicked(point, windows: targets, screen: $0.frame) })
    }

    fileprivate func pressed(at point: CGPoint) {
        dragStart = point
        isDragging = false
    }

    fileprivate func dragged(to point: CGPoint) {
        guard let start = dragStart, let screen = Self.screen(at: start) else { return }
        if !isDragging, hypot(point.x - start.x, point.y - start.y) < 4 { return }
        isDragging = true
        setHighlight(RecordingLayout.dragged(from: start, to: point, within: screen.frame))
    }

    fileprivate func released(at point: CGPoint) {
        guard let start = dragStart, let screen = Self.screen(at: start) else { return }
        let area = isDragging ? RecordingLayout.dragged(from: start, to: point, within: screen.frame)
            : RecordingLayout.clicked(start, windows: targets, screen: screen.frame)
        dragStart = nil
        isDragging = false
        // Too small to mean: back to picking
        guard area.width >= 16, area.height >= 16 else { return moved(to: point) }
        finish(Pick(area: area, screen: screen))
    }

    private func setHighlight(_ area: CGRect?) {
        guard area != highlight else { return }
        highlight = area
        for window in windows { window.contentView?.needsDisplay = true }
    }

    private func finish(_ pick: Pick?) {
        guard let done else { return }
        self.done = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        done(pick)
    }

    private static func screen(at point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// Other apps' ordinary windows on screen, front to back. Their frames don't need Screen Recording, only their
    /// names do.
    private static func windowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != me,
                  info[kCGWindowAlpha as String] as? Double ?? 1 > 0,
                  let bounds = info[kCGWindowBounds as String],
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  rect.width >= 40, rect.height >= 40 else { return nil }
            return RecordingLayout.appKitRect(rect, mainScreenHeight: mainHeight)
        }
    }
}

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// One screen's cover: dimmed, but for what's lit up, with how to pick across the top
private final class PickerView: NSView {
    weak var picker: RecordingPicker?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        picker?.moved(to: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) { picker?.pressed(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { picker?.dragged(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { picker?.released(at: NSEvent.mouseLocation) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            picker?.cancel()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        let origin = window.frame.origin
        if let highlight = picker?.highlight?.offsetBy(dx: -origin.x, dy: -origin.y).intersection(bounds),
           !highlight.isEmpty {
            NSColor.clear.setFill()
            highlight.fill(using: .copy)
            // White with a dark edge, to show on light screens and dark ones
            NSColor.black.withAlphaComponent(0.5).setStroke()
            let edge = NSBezierPath(rect: highlight.insetBy(dx: -2, dy: -2))
            edge.lineWidth = 1
            edge.stroke()
            NSColor.white.setStroke()
            let line = NSBezierPath(rect: highlight.insetBy(dx: -1, dy: -1).intersection(bounds.insetBy(dx: 1, dy: 1)))
            line.lineWidth = 2
            line.stroke()
            let size = RecordingLayout.gifSize(for: highlight.size)
            let label = label("\(size.width) × \(size.height)", size: 12)
            let below = CGPoint(x: highlight.maxX - label.width, y: highlight.minY - label.height - 6)
            drawLabel(label, at: below.y >= bounds.minY + 4 ? below
                      : CGPoint(x: highlight.maxX - label.width - 6, y: highlight.minY + 6))
        }
        let hint = label("Drag across what to record, or click a window. Esc cancels.", size: 13)
        let top = (window.screen?.visibleFrame.maxY ?? window.frame.maxY) - origin.y
        drawLabel(hint, at: CGPoint(x: (bounds.midX - hint.width / 2).rounded(), y: top - hint.height - 16))
    }

    private struct Label {
        let text: NSAttributedString
        var width: CGFloat { (text.size().width + 20).rounded() }
        var height: CGFloat { (text.size().height + 10).rounded() }
    }

    private func label(_ string: String, size: CGFloat) -> Label {
        Label(text: NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]))
    }

    private func drawLabel(_ label: Label, at origin: CGPoint) {
        let box = CGRect(x: origin.x, y: origin.y, width: label.width, height: label.height)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        label.text.draw(at: CGPoint(x: box.minX + 10, y: box.minY + 5))
    }
}

// MARK: Recording

/// While recording: a red line around the area, and the time with a Stop button by it. Neither shows in the GIF, and
/// neither takes the focus from the app you're recording.
@MainActor
final class RecordingControls {
    private let border = RecordingControls.panel()
    private let bar = RecordingControls.panel()
    private let clock = RecordingClock()
    private var ticking: Task<Void, Never>?
    private let stop: () -> Void

    init(around area: CGRect, on screen: NSScreen, stop: @escaping () -> Void) {
        self.stop = stop
        border.ignoresMouseEvents = true
        border.contentView = RecordingBorder()
        // Just outside the area, or inside along a screen's edge
        border.setFrame(area.insetBy(dx: -3, dy: -3).intersection(screen.frame), display: true)
        border.orderFrontRegardless()

        let content = FirstClickHostingView(rootView: RecordingBar(clock: clock, stop: stop))
        let size = content.fittingSize
        bar.contentView = content
        bar.setFrame(RecordingLayout.barFrame(size: size, around: area, in: screen.visibleFrame), display: true)
        bar.orderFrontRegardless()
    }

    /// Counts the seconds, and stops at the limit
    func startClock(stoppingAfter limit: Int) {
        let start = Date()
        ticking = Task { [clock, stop] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let seconds = Int(Date().timeIntervalSince(start))
                clock.seconds = seconds
                if seconds >= limit { return stop() }
            }
        }
    }

    func close() {
        ticking?.cancel()
        border.orderOut(nil)
        bar.orderOut(nil)
    }

    private static func panel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

@Observable @MainActor
final class RecordingClock {
    var seconds = 0
}

private final class RecordingBorder: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(Bubble.red).setStroke()
        let line = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        line.lineWidth = 3
        line.stroke()
    }
}

/// The time so far, and Stop
private struct RecordingBar: View {
    let clock: RecordingClock
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Bubble.red)
                .overlay(Circle().strokeBorder(Bubble.ink, lineWidth: 1.5))
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
            Text(RecordingLayout.clock(clock.seconds))
                .font(Bubble.body(13).monospacedDigit())
                .foregroundStyle(Bubble.ink)
                .accessibilityLabel("Recording, \(clock.seconds) seconds")
            Button("Stop", action: stop)
                .buttonStyle(BubbleButtonStyle(fill: Bubble.yellow, height: 24, fontSize: 12))
                .help("Stop recording (control+option+R)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .bubbleCard()
        .padding(.trailing, 3)
        .padding(.bottom, 4)  // room for the shadow
    }
}

/// Takes the first click, so Stop works while the app you're recording is in front
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One recording: ScreenCaptureKit's frames of part of a display, at most 15 a second, each written into the GIF as it
/// comes. Only its queue touches the writer.
final class GIFRecording: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Result: @unchecked Sendable {
        let file: URL
        let frameCount: Int
        /// How long it plays
        let seconds: Double
        let bytes: Int
        let firstFrame: CGImage?
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private let file: URL
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "io.github.jfreema.yafie.recording", qos: .userInitiated)
    private let onStop: @Sendable (String) -> Void
    private var stream: SCStream?
    /// Made with the first frame, at its size
    private var writer: GIFWriter?
    private var firstFrame: CGImage?
    private var isStopped = false

    private init(file: URL, onStop: @escaping @Sendable (String) -> Void) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw Failure(errorDescription: "The GIF couldn't be made in \(file.deletingLastPathComponent().path).")
        }
        self.file = file
        handle = try FileHandle(forWritingTo: file)
        self.onStop = onStop
    }

    /// - Parameters:
    ///   - area: in points from the top left of the display
    ///   - onStop: when ScreenCaptureKit stops by itself, with why
    static func start(display: CGDirectDisplayID, area: CGRect, size: RecordingLayout.Size, file: URL,
                      onStop: @escaping @Sendable (String) -> Void) async throws -> GIFRecording {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let screen = content.displays.first(where: { $0.displayID == display }) else {
            throw Failure(errorDescription: "That display isn't connected anymore.")
        }
        // Yafie's own windows stay out: the red line, Stop, and any menu or message
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = content.applications.filter { $0.processID == me }
        let filter = apps.isEmpty
            ? SCContentFilter(display: screen, excludingWindows: content.windows.filter {
                $0.owningApplication?.processID == me
            })
            : SCContentFilter(display: screen, excludingApplications: apps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = area
        configuration.width = size.width
        configuration.height = size.height
        configuration.preservesAspectRatio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        configuration.queueDepth = 5

        let recording = try GIFRecording(file: file, onStop: onStop)
        do {
            let stream = SCStream(filter: filter, configuration: configuration, delegate: recording)
            try stream.addStreamOutput(recording, type: .screen, sampleHandlerQueue: recording.queue)
            try await stream.startCapture()
            recording.stream = stream
        } catch {
            try? recording.handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return recording
    }

    /// Ends the GIF with the last frame up until now
    func stop() async -> Result {
        let end = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        try? await stream?.stopCapture()
        return await withCheckedContinuation { continuation in
            // After any frames still in line
            queue.async { [self] in
                isStopped = true
                writer?.finish(at: end)
                let bytes = (try? handle.offset()).map(Int.init) ?? 0
                try? handle.close()
                continuation.resume(returning: Result(file: file, frameCount: writer?.frameCount ?? 0,
                                                      seconds: Double(writer?.length ?? 0) / 100, bytes: bytes,
                                                      firstFrame: firstFrame))
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !isStopped, Self.isComplete(sampleBuffer), let buffer = sampleBuffer.imageBuffer,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
        if writer == nil {
            let handle = handle
            writer = GIFWriter(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) {
                try? handle.write(contentsOf: $0)
            }
        }
        guard let writer,
              let pixels = Self.pixels(of: buffer, width: writer.width, height: writer.height) else { return }
        if firstFrame == nil { firstFrame = RecordingLayout.image(pixels, width: writer.width, height: writer.height) }
        writer.add(pixels, at: sampleBuffer.presentationTimeStamp.seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop(error.localizedDescription)
    }

    /// A new picture, or the first. Not the idle frames that say nothing changed, or the blank ones while the screen's
    /// asleep.
    private static func isComplete(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init) else { return false }
        return status == .complete || status == .started
    }

    /// The frame as the writer takes it, cut or filled out to its size in case one ever comes at another
    private static func pixels(of buffer: CVPixelBuffer, width: Int, height: Int) -> [UInt32]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rows = min(height, CVPixelBufferGetHeight(buffer)), columns = min(width, CVPixelBufferGetWidth(buffer))
        var pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
        pixels.withUnsafeMutableBytes { pixels in
            for row in 0..<rows {
                memcpy(pixels.baseAddress! + row * width * 4, base + row * stride, columns * 4)
            }
        }
        return pixels
    }
}

// MARK: Layout

/// Where a recording's pieces go, and how big its GIF is
enum RecordingLayout {
    struct Size: Equatable, Sendable {
        var width: Int
        var height: Int
    }

    /// The most pixels across or down a GIF
    static let longestSide = 1280

    /// A pixel a point, which keeps text readable and files small enough to send, down to 1280 pixels at most
    static func gifSize(for area: CGSize) -> Size {
        let fit = min(1, CGFloat(longestSide) / max(area.width, area.height, 1))
        return Size(width: max(1, Int((area.width * fit).rounded())),
                    height: max(1, Int((area.height * fit).rounded())))
    }

    /// An area as ScreenCaptureKit takes it: in points from the top left of its display
    static func displayRect(_ area: CGRect, on screen: CGRect) -> CGRect {
        CGRect(x: area.minX - screen.minX, y: screen.maxY - area.maxY, width: area.width, height: area.height)
    }

    /// A window's bounds from the window server, from the top left of the main screen, as AppKit counts them, from its
    /// bottom left
    static func appKitRect(_ bounds: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: mainScreenHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// What a click picks: the frontmost window under the pointer, as much as is on its screen, or else the screen
    static func clicked(_ point: CGPoint, windows: [CGRect], screen: CGRect) -> CGRect {
        guard let window = windows.first(where: { $0.contains(point) }) else { return screen }
        let visible = window.intersection(screen).integral.intersection(screen)
        return visible.isEmpty ? screen : visible
    }

    /// A drag, kept to the screen it started on, in whole points
    static func dragged(from start: CGPoint, to end: CGPoint, within screen: CGRect) -> CGRect {
        let area = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        let visible = area.intersection(screen)
        return visible.isNull ? .zero : visible.integral.intersection(screen)
    }

    /// Where Stop goes: centered under the area, else over it, else inside it along the bottom, on the screen
    static func barFrame(size: CGSize, around area: CGRect, in visible: CGRect) -> CGRect {
        let gap: CGFloat = 10, margin: CGFloat = 8
        let x = min(max(area.midX - size.width / 2, visible.minX + margin), visible.maxX - margin - size.width)
        let below = area.minY - gap - size.height, above = area.maxY + gap
        let y = if below >= visible.minY + margin {
            below
        } else if above + size.height <= visible.maxY - margin {
            above
        } else {
            max(area.minY, visible.minY) + gap
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// "0:07"
    static func clock(_ seconds: Int) -> String {
        "\(seconds / 60):" + (seconds % 60 < 10 ? "0" : "") + "\(seconds % 60)"
    }

    /// "8 seconds · 3.2 MB", under the picture in the menu
    static func summary(seconds: Double, bytes: Int) -> String {
        let whole = max(1, Int(seconds.rounded()))
        let size = bytes < 1_000_000 ? "\(max(1, (bytes + 500) / 1000)) KB"
            : String(format: "%.1f MB", Double(bytes) / 1_000_000)
        return "\(whole) \(whole == 1 ? "second" : "seconds") · \(size)"
    }

    /// The writer's pixels as an image, for the menu's picture
    static func image(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        guard pixels.count == width * height,
              let provider = CGDataProvider(data: pixels.withUnsafeBytes { Data($0) } as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// At most 200 × 120 points, a pixel a point as recorded
    @MainActor
    static func thumbnail(of frame: CGImage) -> NSImage {
        let fit = min(1, 200 / CGFloat(frame.width), 120 / CGFloat(frame.height))
        return NSImage(cgImage: frame, size: NSSize(width: max(1, (CGFloat(frame.width) * fit).rounded()),
                                                    height: max(1, (CGFloat(frame.height) * fit).rounded())))
    }
}

extension NSScreen {
    /// The display ScreenCaptureKit knows it by
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
