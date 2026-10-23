import AppKit
import SwiftUI

/// The tuner's floating window. It listens only while open.
@MainActor
final class TunerWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "Tuner"
    private static let privacySettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// How loud the tuner's input is, for the menu bar icon. Nil while the tuner is closed.
    private(set) var loudness: LoudnessMeter.Loudness? {
        didSet { if loudness != oldValue { onLoudnessChange?() } }
    }
    var onLoudnessChange: (() -> Void)?

    private let model = TunerModel()
    private var meter = LoudnessMeter()
    private lazy var audio = TunerAudio(onStatus: { [weak self] status in self?.statusChanged(status) },
                                        onHeard: { [weak self] heard in self?.heard(heard) })
    private lazy var panel = makePanel()

    func show() {
        // An accessory app's window can open behind others
        NSApp.activate()
        let opening = !panel.isVisible
        panel.makeKeyAndOrderFront(nil)
        if opening {
            hush()
            audio.start()
        }
    }

    func windowWillClose(_ notification: Notification) {
        audio.stop()
        model.reset()
        meter = LoudnessMeter()
        loudness = nil
    }

    private func statusChanged(_ status: TunerAudio.Status) {
        model.status = status
        if status != .listening { hush() }  // no news while it starts over
    }

    private func heard(_ heard: Heard) {
        model.heard(heard.pitch)
        loudness = meter.update(heard.level, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Green until it hears something
    private func hush() {
        meter = LoudnessMeter()
        loudness = .quiet
    }

    /// Back from System Settings, or a microphone plugged in
    func windowDidBecomeKey(_ notification: Notification) {
        switch model.status {
        case .denied where TunerAudio.isMicrophoneAllowed, .noInput, .failed: audio.start()
        default: break
        }
    }

    private func makePanel() -> NSPanel {
        let view = TunerView(model: model, retry: { [weak self] in self?.audio.start() },
                             openPrivacySettings: { NSWorkspace.shared.open(Self.privacySettings) })
        let panel = UtilityPanel(contentRect: NSRect(origin: .zero, size: TunerView.size),
                               styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Tuner"
        panel.useBubbleChrome()
        panel.contentView = UtilityPanel.content(view)
        panel.isFloatingPanel = true
        // Panels hide when their app deactivates, which would make the tuner vanish at the first click elsewhere
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.restoreFrame(named: Self.frameName, size: TunerView.size)
        return panel
    }
}

/// The tuner's and the drum machine's. Esc and ⌘W close it, though Yafie has no menu bar to carry them.
final class UtilityPanel: NSPanel {
    /// A view that fills the panel, its size set by the panel rather than the view
    static func content(_ view: some View) -> NSView {
        let content = NSHostingView(rootView: view)
        content.sizingOptions = []
        return content
    }

    /// Back where it was last time, at this size: one saved before the bubble pop look had another
    func restoreFrame(named name: String, size: CGSize) {
        let restored = setFrameUsingName(name)
        setContentSize(size)
        if !restored { center() }
        setFrameAutosaveName(name)
    }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: Model

/// What the tuner window shows
@Observable @MainActor
final class TunerModel {
    struct Reading: Equatable {
        /// Within this many cents counts as in tune
        static let tolerance = 3.0

        let note: Note
        let frequency: Double
        /// The sound stopped: the last reading, shown dimmed for a moment
        let isHeld: Bool

        var isInTune: Bool { abs(note.cents) <= Self.tolerance }
    }

    var status = TunerAudio.Status.starting
    private(set) var reading: Reading?
    @ObservationIgnored private var smoother = PitchSmoother()

    func heard(_ pitch: Pitch?) {
        let shown = smoother.update(midi: pitch.map { Note.midi(for: $0.frequency) },
                                    at: ProcessInfo.processInfo.systemUptime)
        let next = shown.map { Reading(note: Note(midi: $0.midi), frequency: Note.frequency(for: $0.midi), isHeld: $0.isHeld) }
        if next != reading { reading = next }
    }

    func reset() {
        status = .starting
        reading = nil
        smoother = PitchSmoother()
    }
}

/// Steadies raw estimates for display: a median against outliers, a guard against octave errors, and a short hold
struct PitchSmoother {
    static let count = 5
    static let hold: TimeInterval = 1
    /// About an octave or more, in semitones. It takes this many agreeing estimates in a row to jump that far.
    static let jump = 10.0
    static let jumpRun = 3

    struct Shown: Equatable {
        /// Fractional MIDI number
        var midi: Double
        var isHeld: Bool
    }

    private var recent: [Double] = []
    private var shown: Double?
    private var agreeing = 0
    private var lastHeard = -Double.infinity

    /// Takes every estimate, nil when nothing clear was heard
    mutating func update(midi estimate: Double?, at time: TimeInterval) -> Shown? {
        guard let estimate else {
            guard let shown, time - lastHeard <= Self.hold else {
                self = PitchSmoother()
                return nil
            }
            return Shown(midi: shown, isHeld: true)
        }
        agreeing = recent.last.map { abs($0 - estimate) < 1 } == true ? agreeing + 1 : 1
        recent.append(estimate)
        if recent.count > Self.count { recent.removeFirst() }
        lastHeard = time
        let median = recent.sorted()[recent.count / 2]
        if let shown, abs(median - shown) > Self.jump, agreeing < Self.jumpRun {
            return Shown(midi: shown, isHeld: false)
        }
        shown = median
        return Shown(midi: median, isHeld: false)
    }
}

/// The loudest recent level, falling back slowly so the menu bar icon doesn't flicker, sorted into its colors
struct LoudnessMeter {
    enum Loudness: Equatable { case quiet, soft, medium, loud, veryLoud }

    /// dB per second
    static let fall: Float = 30
    /// Where each band starts, in dBFS. Anything quieter than soft counts as quiet.
    static let soft: Float = -55
    static let medium: Float = -40
    static let loud: Float = -30
    static let veryLoud: Float = -20

    private var level = -Float.infinity
    private var lastUpdate: TimeInterval?

    mutating func update(_ heard: Float, at time: TimeInterval) -> Loudness {
        if let lastUpdate { level -= Self.fall * Float(time - lastUpdate) }
        lastUpdate = time
        level = max(level, heard)
        switch level {
        case ..<Self.soft: return .quiet
        case ..<Self.medium: return .soft
        case ..<Self.loud: return .medium
        case ..<Self.veryLoud: return .loud
        default: return .veryLoud
        }
    }
}

// MARK: Views

/// Blue, with the reading on a white card. It fills the window, title bar and all, so its size is the window's.
struct TunerView: View {
    static let size = CGSize(width: 480, height: 380)

    let model: TunerModel
    let retry: () -> Void
    let openPrivacySettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            BubbleHeader(title: "Guitar Tuner", symbol: "tuningfork", chip: Bubble.yellow)
            Group {
                switch model.status {
                case .starting, .listening:
                    ReadingView(reading: model.reading, isStarting: model.status == .starting)
                case .denied:
                    MessageView(symbol: "mic.slash", title: "\(Yafie.name) can't use the microphone",
                                detail: "Allow it in System Settings, then come back to this window.",
                                button: "Open Privacy Settings", action: openPrivacySettings)
                case .noInput:
                    MessageView(symbol: "mic.slash", title: "No microphone the tuner can use",
                                detail: "Connect a wired one. The tuner never uses Bluetooth microphones, which switch "
                                    + "headsets to call mode.",
                                button: "Try Again", action: retry)
                case .failed(let message):
                    MessageView(symbol: "exclamationmark.triangle", title: "Couldn't start listening",
                                detail: message, button: "Try Again", action: retry)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .bubbleCard()
            .padding(.trailing, 2)
            .padding(.bottom, 3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Bubble.blue.ignoresSafeArea())
    }
}

private struct ReadingView: View {
    let reading: TunerModel.Reading?
    let isStarting: Bool

    var body: some View {
        let isInTune = reading?.isInTune == true
        VStack(spacing: 10) {
            Group {
                if let reading {
                    NoteName(note: reading.note)
                        .foregroundStyle(reading.isInTune ? Bubble.deepGreen : Bubble.ink)
                } else {
                    Text(isStarting ? "Waiting for the microphone…" : "Play a string")
                        .font(Bubble.display(22))
                        .foregroundStyle(Bubble.ink.opacity(0.4))
                }
            }
            .frame(height: 114)
            CentsMeter(cents: reading?.note.cents, isInTune: isInTune)
                .frame(height: 69)
            Text(caption)
                .font(Bubble.body(15))
                .monospacedDigit()
                .foregroundStyle(Bubble.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .bubbleCard(fill: isInTune ? Bubble.green : Bubble.tint, radius: 8, lift: 2)
                .opacity(reading == nil ? 0 : 1)
        }
        .opacity(reading?.isHeld == true ? 0.4 : 1)
        .animation(.easeOut(duration: 0.2), value: reading?.isHeld)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var caption: String {
        guard let reading else { return " " }  // keeps the line's height
        let hertz = String(format: "%.1f Hz", reading.frequency)
        return reading.isInTune ? "In tune · \(hertz)" : "\(Self.cents(reading.note.cents)) · \(hertz)"
    }

    private var spoken: String {
        guard let reading else { return isStarting ? "Waiting for the microphone" : "Play a string" }
        let note = "\(reading.note.name.replacingOccurrences(of: "♯", with: " sharp")) \(reading.note.octave)"
        if reading.isInTune { return "\(note), in tune" }
        let cents = Int(abs(reading.note.cents).rounded())
        return "\(note), \(cents) \(cents == 1 ? "cent" : "cents") \(reading.note.cents > 0 ? "sharp" : "flat")"
    }

    /// "+4 cents", "−12 cents"
    static func cents(_ value: Double) -> String {
        let whole = Int(value.rounded())
        let sign = whole > 0 ? "+" : whole < 0 ? "−" : ""
        return "\(sign)\(abs(whole)) \(abs(whole) == 1 ? "cent" : "cents")"
    }
}

private struct NoteName: View {
    let note: Note

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(note.name)
                .font(Bubble.display(96))
            Text(verbatim: "\(note.octave)")
                .font(Bubble.display(39))
                .opacity(0.45)
                .baselineOffset(-15)
        }
    }
}

/// −50 to +50 cents, with a needle
private struct CentsMeter: View {
    let cents: Double?
    let isInTune: Bool

    /// Room for ♭ and ♯ at the ends
    private static let inset: CGFloat = 33
    private static let midline: CGFloat = 21
    private static let marks = Bubble.ink.opacity(0.45)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            Canvas { context, size in
                let left = Self.x(-TunerModel.Reading.tolerance, in: size.width)
                let right = Self.x(TunerModel.Reading.tolerance, in: size.width)
                context.fill(Path(roundedRect: CGRect(x: left, y: 0, width: right - left, height: 2 * Self.midline),
                                  cornerRadius: 4.5), with: .color(Bubble.green.opacity(0.35)))
                for step in stride(from: -50, through: 50, by: 5) {
                    let length: CGFloat = step == 0 ? 42 : step % 25 == 0 ? 27 : 15
                    let x = Self.x(Double(step), in: size.width)
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: Self.midline - length / 2))
                    tick.addLine(to: CGPoint(x: x, y: Self.midline + length / 2))
                    context.stroke(tick, with: .color(step == 0 ? Bubble.ink : Self.marks),
                                   style: StrokeStyle(lineWidth: step == 0 ? 3 : 2, lineCap: .round))
                }
                for step in [-50, -25, 0, 25, 50] {
                    let label = step > 0 ? "+\(step)" : step < 0 ? "−\(-step)" : "0"
                    context.draw(Text(label).font(Bubble.body(14)).foregroundStyle(Self.marks),
                                 at: CGPoint(x: Self.x(Double(step), in: size.width), y: 2 * Self.midline + 15))
                }
                context.draw(Text("♭").font(Bubble.display(22)).foregroundStyle(Self.marks),
                             at: CGPoint(x: 12, y: Self.midline))
                context.draw(Text("♯").font(Bubble.display(22)).foregroundStyle(Self.marks),
                             at: CGPoint(x: size.width - 12, y: Self.midline))
            }
            .overlay(alignment: .topLeading) {
                if let cents {
                    Capsule()
                        .fill(isInTune ? Bubble.green : Bubble.yellow)
                        .overlay(Capsule().strokeBorder(Bubble.ink, lineWidth: 2))
                        .frame(width: 10, height: 2 * Self.midline + 8)
                        .position(x: Self.x(cents, in: width), y: Self.midline)
                        .animation(.easeOut(duration: 0.1), value: cents)
                }
            }
        }
    }

    private static func x(_ cents: Double, in width: CGFloat) -> CGFloat {
        inset + CGFloat(min(max(cents, -50), 50) + 50) / 100 * (width - 2 * inset)
    }
}

/// Why it can't go on, and what to do. The tuner's and the drum machine's, on their white card.
struct MessageView: View {
    let symbol: String
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Bubble.ink)
                .frame(width: 48, height: 48)
                .bubbleCard(fill: Bubble.yellow, radius: 12, lift: 3)
            Text(title)
                .font(Bubble.display(19))
                .foregroundStyle(Bubble.ink)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(Bubble.body(14))
                .foregroundStyle(Bubble.ink.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(button, action: action)
                .buttonStyle(BubbleButtonStyle(fill: Bubble.yellow, height: 30, fontSize: 13.5))
                .padding(.top, 4)
        }
    }
}
