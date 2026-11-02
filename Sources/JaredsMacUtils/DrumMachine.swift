import AppKit
import SwiftUI

/// The drum machine's floating window. Its sound plays only while it's open.
@MainActor
final class DrumMachineWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "Drums"

    private let model = DrumMachineModel()
    private lazy var audio = DrumAudio(onStatus: { [weak self] status in self?.statusChanged(status) },
                                       onMessage: { [weak self] message in self?.model.received(message) })
    private lazy var panel = makePanel()
    private var keyMonitor: Any?

    override init() {
        super.init()
        model.send = { [weak self] command in self?.audio.send(command) }
    }

    func show() {
        // An accessory app's window can open behind others
        NSApp.activate()
        let opening = !panel.isVisible
        panel.makeKeyAndOrderFront(nil)
        guard opening else { return }
        audio.start()
        watchSpace()
    }

    func windowWillClose(_ notification: Notification) {
        audio.stop()
        model.closed()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func statusChanged(_ status: DrumAudio.Status) {
        model.status = status
        if status == .ready { model.playerStarted() }
    }

    /// Space plays and stops while the drum machine has the keyboard
    private func watchSpace() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isSpace = event.charactersIgnoringModifiers == " "
                && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            let played = MainActor.assumeIsolated {
                guard let self, isSpace, event.window === self.panel else { return false }
                self.model.togglePlay()
                return true
            }
            return played ? nil : event
        }
    }

    private func makePanel() -> NSPanel {
        let view = DrumMachineView(model: model, retry: { [weak self] in self?.audio.start() })
        let panel = UtilityPanel(contentRect: NSRect(origin: .zero, size: DrumMachineView.size),
                                 styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.title = "Drum Machine"
        panel.useBubbleChrome()
        panel.contentView = UtilityPanel.content(view)
        panel.isFloatingPanel = true
        // Panels hide when their app deactivates, which would make the drums vanish at the first click elsewhere
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.restoreFrame(named: Self.frameName, size: DrumMachineView.size)
        return panel
    }
}

// MARK: Model

/// What the drum machine shows, and what it asks the player to do. The loop is kept here too, so a player that
/// starts over gets it back.
@Observable @MainActor
final class DrumMachineModel {
    struct Beat: Equatable {
        /// From 1. Bar 0 is the count-in.
        var bar: Int
        var beat: Int
        var phase: DrumSequencer.Phase
        /// Of a recording, from 1
        var pass: Int
    }

    var status = DrumAudio.Status.starting
    private(set) var isPlaying = false
    /// What's sounding now. Nil while stopped.
    private(set) var beat: Beat?
    /// Pads hit in the last moment, lit up
    private(set) var lit: Set<DrumPad> = []
    private(set) var pattern: Set<DrumNote> = []

    /// Beats a minute, set with setTempo
    private(set) var tempo: Double
    var isMetronomeOn: Bool {
        didSet {
            defaults.set(isMetronomeOn, forKey: Keys.metronome)
            send(.metronome(isMetronomeOn))
        }
    }
    /// Taps light their pads and record, but make no sound: for Bluetooth headphones, which play them late
    var areTapsMuted: Bool {
        didSet {
            defaults.set(areTapsMuted, forKey: Keys.muteTaps)
            send(.muteTaps(areTapsMuted))
        }
    }
    /// How much later than they tell macOS Bluetooth headphones play, in milliseconds, set with setBluetoothOffset.
    /// Hits played along to them sound that much earlier, even ones already in the loop.
    private(set) var bluetoothOffset: Double
    /// How the loop's hits snap to the beat. It can change any time, since the loop keeps them as played.
    var quantize: DrumQuantize {
        didSet {
            defaults.set(quantize.rawValue, forKey: Keys.quantize)
            send(.quantize(quantize))
        }
    }
    var feel: DrumFeel {
        didSet {
            defaults.set(feel.rawValue, forKey: Keys.feel)
            send(.feel(feel))
        }
    }
    private(set) var feelAmount: Double

    func setFeelAmount(_ value: Double) {
        feelAmount = DrumSequencer.clampedFeelAmount(value).rounded()
        defaults.set(feelAmount, forKey: Keys.feelAmount)
        send(.feelAmount(feelAmount))
    }

    /// 1 or 4
    var bars: Int {
        didSet {
            guard bars != oldValue else { return }
            defaults.set(bars, forKey: Keys.bars)
            pattern = DrumSequencer.resized(pattern, from: oldValue, to: bars)
            send(.bars(bars))
        }
    }

    /// To the player
    @ObservationIgnored var send: (DrumCommand) -> Void = { _ in }
    @ObservationIgnored private let defaults: UserDefaults
    /// Counts each pad's flashes, so an early one doesn't put out a later one
    @ObservationIgnored private var flashes: [DrumPad: Int] = [:]

    private enum Keys {
        static let tempo = "drumTempo"
        static let metronome = "drumMetronome"
        static let muteTaps = "drumMuteTaps"
        static let bluetoothOffset = "drumBluetoothOffset"
        static let quantize = "drumQuantize"
        static let feel = "drumFeel"
        static let feelAmount = "drumFeelAmount"
        static let bars = "drumBars"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tempo = defaults.object(forKey: Keys.tempo) as? Double ?? 100
        isMetronomeOn = defaults.object(forKey: Keys.metronome) as? Bool ?? true
        areTapsMuted = defaults.bool(forKey: Keys.muteTaps)
        bluetoothOffset = Self.steppedOffset(defaults.double(forKey: Keys.bluetoothOffset))
        quantize = defaults.string(forKey: Keys.quantize).flatMap(DrumQuantize.init) ?? .sixteenth
        feel = defaults.string(forKey: Keys.feel).flatMap(DrumFeel.init) ?? .straight
        feelAmount = DrumSequencer.clampedFeelAmount(defaults.object(forKey: Keys.feelAmount) as? Double ?? 100)
        bars = defaults.integer(forKey: Keys.bars) == 4 ? 4 : 1
    }

    var phase: DrumSequencer.Phase? { beat?.phase }

    /// In whole beats a minute, from 40 to 240
    func setTempo(_ value: Double) {
        let tempo = min(max(value.rounded(), DrumSequencer.tempos.lowerBound), DrumSequencer.tempos.upperBound)
        guard tempo != self.tempo else { return }
        self.tempo = tempo
        defaults.set(tempo, forKey: Keys.tempo)
        send(.tempo(tempo))
    }

    /// In steps of 5 milliseconds, from 0 to 400
    func setBluetoothOffset(_ value: Double) {
        let offset = Self.steppedOffset(value)
        guard offset != bluetoothOffset else { return }
        bluetoothOffset = offset
        defaults.set(offset, forKey: Keys.bluetoothOffset)
        send(.bluetoothOffset(offset))
    }

    private static func steppedOffset(_ value: Double) -> Double {
        let range = DrumSequencer.bluetoothOffsets
        return min(max((value / 5).rounded() * 5, range.lowerBound), range.upperBound)
    }

    func hit(_ pad: DrumPad) {
        flash(pad)
        send(.hit(pad))
    }

    func togglePlay() {
        if isPlaying {
            send(.stop)
            isPlaying = false
            beat = nil
        } else {
            send(.play)
            isPlaying = true
        }
    }

    /// Records two passes round the loop, after a bar's count-in when it's stopped
    func record() {
        send(.record)
        isPlaying = true
    }

    func clear() {
        send(.clear)
        pattern = []
    }

    func received(_ message: DrumMessage) {
        switch message {
        case let .beat(bar, beat, phase, pass):
            if isPlaying { self.beat = Beat(bar: bar, beat: beat, phase: phase, pass: pass) }
        case .played(let pad):
            flash(pad)
        case .recorded(let note):
            pattern.insert(note)
        case .ready, .alive, .changed, .failed:
            break
        }
    }

    /// A new player knows nothing yet, so it's told everything. A count-in or a recording pass that was going is lost.
    func playerStarted() {
        send(.tempo(tempo))
        send(.metronome(isMetronomeOn))
        send(.muteTaps(areTapsMuted))
        send(.bluetoothOffset(bluetoothOffset))
        send(.bars(bars))
        send(.quantize(quantize))
        send(.feel(feel))
        send(.feelAmount(feelAmount))
        send(.load(pattern))
        if isPlaying { send(.play) }
    }

    /// The window closed, and the player with it. The loop stays for next time.
    func closed() {
        isPlaying = false
        beat = nil
        lit = []
        status = .starting
    }

    private func flash(_ pad: DrumPad) {
        lit.insert(pad)
        flashes[pad, default: 0] += 1
        let count = flashes[pad]
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            if flashes[pad] == count { lit.remove(pad) }
        }
    }
}

// MARK: Views

/// The pads on blue over the controls on a white card. All its state is in the model: the Command Line Tools can't
/// build SwiftUI's @State. It fills the window, title bar and all, so its size is the window's.
struct DrumMachineView: View {
    static let size = CGSize(width: 540, height: 640)

    let model: DrumMachineModel
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            BubbleHeader(title: "Drum Machine", symbol: "music.quarternote.3", chip: Bubble.green)
            switch model.status {
            case .failed(let message):
                MessageView(symbol: "speaker.slash", title: "Couldn't play sound", detail: message,
                            button: "Try Again", action: retry)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .bubbleCard()
                    .padding(.trailing, 2)
                    .padding(.bottom, 3)
            case .starting, .ready:
                DrumPads(model: model)
                    .padding(.trailing, 3)
                    .padding(.bottom, 4)  // room for the shadows
                Text("Tap the trackpad where the pads are, with the pointer over them, or click them.")
                    .font(Bubble.body(12))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                DrumControls(model: model)
                    .padding(14)
                    .bubbleCard()
                    .padding(.trailing, 2)
                    .padding(.bottom, 3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Bubble.blue.ignoresSafeArea())
    }
}

/// Snare and kick on top, a hi-hat on either side below, as on the trackpad
private struct DrumPads: View {
    let model: DrumMachineModel

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                DrumPadView(pad: .snare, model: model)
                DrumPadView(pad: .kick, model: model)
            }
            GridRow {
                DrumPadView(pad: .hiHat, model: model)
                DrumPadView(pad: .hiHat, model: model)
            }
        }
        .overlay { TrackpadCatcher { model.hit($0) } }
    }
}

/// A big outlined pad on a hard shadow. A hit fills it with its color and presses it down into the shadow.
private struct DrumPadView: View {
    private static let lift: CGFloat = 4

    let pad: DrumPad
    let model: DrumMachineModel

    var body: some View {
        let isLit = model.lit.contains(pad)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let sink = isLit ? Self.lift - 1 : 0
        shape.fill(Color.white)
            .overlay(shape.fill(pad.color.opacity(isLit ? 1 : 0.35)))
            .overlay {
                Text(pad.name)
                    .font(Bubble.display(24))
                    .foregroundStyle(Bubble.ink)
            }
            .overlay(shape.strokeBorder(Bubble.ink, lineWidth: 2.5))
            .offset(x: sink * 0.6, y: sink)
            .background(shape.fill(Bubble.ink).offset(x: Self.lift * 0.6, y: Self.lift))
            .animation(.easeOut(duration: 0.12), value: isLit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pad.name)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.hit(pad) }
    }
}

private extension DrumPad {
    var color: Color {
        switch self {
        case .kick: Bubble.orange
        case .snare: Bubble.yellow
        case .hiHat: Bubble.green
        }
    }
}

private struct DrumControls: View {
    let model: DrumMachineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { model.togglePlay() } label: {
                    Label(model.isPlaying ? "Stop" : "Play", systemImage: model.isPlaying ? "stop.fill" : "play.fill")
                        .frame(minWidth: 56)
                }
                .buttonStyle(BubbleButtonStyle(fill: model.isPlaying ? Bubble.yellow : Bubble.green, height: 30,
                                               fontSize: 13))
                .help("Play or stop (Space)")
                Button { model.record() } label: {
                    Label {
                        Text("Record")
                    } icon: {
                        Image(systemName: "record.circle.fill").foregroundStyle(Bubble.red)
                    }
                }
                .buttonStyle(BubbleButtonStyle(height: 30, fontSize: 13))
                .disabled(model.phase == .countIn || model.phase == .recording)
                .help("Record two passes round the loop, with a bar's count-in when stopped")
                Button("Clear") { model.clear() }
                    .buttonStyle(BubbleButtonStyle(height: 30, fontSize: 13))
                    .disabled(model.pattern.isEmpty)
                    .help("Clear the loop")
                Spacer(minLength: 0)
                BeatLights(beat: model.beat, bars: model.bars)
            }
            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    ControlLabel("Loop")
                    ChoiceChip(title: "1 Bar", isChosen: model.bars == 1) { model.bars = 1 }
                    ChoiceChip(title: "4 Bars", isChosen: model.bars == 4) { model.bars = 4 }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Loop")
                HStack(spacing: 6) {
                    ControlLabel("Quantize")
                    ForEach(DrumQuantize.allCases, id: \.self) { quantize in
                        ChoiceChip(title: quantize.name, isChosen: model.quantize == quantize) {
                            model.quantize = quantize
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Quantize")
                .help("Snap the loop's hits to the nearest quarter, eighth or sixteenth note, or play them as you did")
            }
            HStack(spacing: 8) {
                ControlLabel("Feel")
                Picker("Feel", selection: Binding(get: { model.feel }, set: { model.feel = $0 })) {
                    ForEach(DrumFeel.allCases, id: \.self) { feel in
                        Text(feel.name).tag(feel)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Swing alternates subdivisions; Laid Back delays backbeats; Loose Garage pushes and pulls")
                ControlLabel("Amount")
                    .padding(.leading, 8)
                Slider(value: Binding(get: { model.feelAmount }, set: { model.setFeelAmount($0) }), in: 0...100)
                    .accessibilityLabel("Amount")
                ControlValue(text: "\(Int(model.feelAmount))%", width: 44)
            }
            .disabled(model.quantize == .none)
            .help("Feel changes the loop, leaving live taps and the metronome steady. Quantize None bypasses it")
            HStack(spacing: 8) {
                ControlLabel("Tempo")
                Slider(value: Binding(get: { model.tempo }, set: { model.setTempo($0) }), in: DrumSequencer.tempos)
                    .accessibilityLabel("Tempo")
                Stepper(value: Binding(get: { model.tempo }, set: { model.setTempo($0) }), in: DrumSequencer.tempos) {
                    ControlValue(text: "\(Int(model.tempo)) BPM", width: 64)
                }
                Toggle("Metronome", isOn: Binding(get: { model.isMetronomeOn }, set: { model.isMetronomeOn = $0 }))
                    .toggleStyle(ChipToggleStyle())
                    .padding(.leading, 6)
            }
            HStack(spacing: 8) {
                Toggle("Mute Taps", isOn: Binding(get: { model.areTapsMuted }, set: { model.areTapsMuted = $0 }))
                    .toggleStyle(ChipToggleStyle())
                    .help("Silence your taps, which Bluetooth headphones play late. They still light up and record")
                Group {
                    ControlLabel("Bluetooth Offset")
                        .padding(.leading, 8)
                    Slider(value: Binding(get: { model.bluetoothOffset }, set: { model.setBluetoothOffset($0) }),
                           in: DrumSequencer.bluetoothOffsets)
                        .accessibilityLabel("Bluetooth Offset")
                    ControlValue(text: "\(Int(model.bluetoothOffset)) ms", width: 52)
                }
                .help("Move hits played over Bluetooth earlier, for headphones that play later than they tell macOS")
            }
        }
        .tint(Bubble.blue)
    }
}

/// A control's name, small, upper case and letter-spaced, like the menu's section names. It fades with its control.
private struct ControlLabel: View {
    let text: String
    @Environment(\.isEnabled) private var isEnabled

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .black, design: .rounded))
            .kerning(1.1)
            .foregroundStyle(Bubble.ink.opacity(isEnabled ? 0.55 : 0.25))
            .fixedSize()
            .accessibilityHidden(true)  // the control says it
    }
}

/// A slider's reading, as 120 BPM. It fades with its control.
private struct ControlValue: View {
    let text: String
    let width: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(text)
            .font(Bubble.body(12.5))
            .monospacedDigit()
            .foregroundStyle(Bubble.ink.opacity(isEnabled ? 1 : 0.4))
            .frame(width: width, alignment: .trailing)
    }
}

/// One of a few choices, as a pill that turns yellow when it's the one chosen
private struct ChoiceChip: View {
    let title: String
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(title, action: choose)
            .buttonStyle(BubbleButtonStyle(fill: isChosen ? Bubble.yellow : .white, height: 24, fontSize: 12))
            .fixedSize()
            .accessibilityAddTraits(isChosen ? [.isSelected] : [])
    }
}

/// The bar's four beats, the one sounding lit: orange in the count-in, red while recording
private struct BeatLights: View {
    let beat: DrumMachineModel.Beat?
    let bars: Int

    var body: some View {
        HStack(spacing: 7) {
            Text(caption)
                .font(Bubble.body(12))
                .monospacedDigit()
                .foregroundStyle(Bubble.ink.opacity(0.6))
                .lineLimit(1)
            ForEach(1...DrumSequencer.beatsPerBar, id: \.self) { index in
                let light = RoundedRectangle(cornerRadius: 4, style: .continuous)
                light.fill(index == beat?.beat ? color : Bubble.tint)
                    .overlay(light.strokeBorder(Bubble.ink, lineWidth: 1.5))
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(beat.map { "\(caption), beat \($0.beat)" } ?? "Stopped")
    }

    private var caption: String {
        guard let beat else { return "" }
        let bar = bars > 1 ? "Bar \(beat.bar) of \(bars)" : ""
        switch beat.phase {
        case .countIn: return "Count-in"
        case .recording:
            // Short enough for one line beside the lights
            let pass = "\(beat.pass) of \(DrumSequencer.recordingPasses)"
            return bars > 1 ? "Pass \(pass) · Bar \(beat.bar)" : "Recording \(pass)"
        case .playing: return bar
        }
    }

    private var color: Color {
        switch beat?.phase {
        case .countIn: Bubble.orange
        case .recording: Bubble.red
        default: Bubble.blue
        }
    }
}

/// Over the pads, catching the trackpad's touches and clicks
private struct TrackpadCatcher: NSViewRepresentable {
    let onPad: (DrumPad) -> Void

    func makeNSView(context: Context) -> TrackpadPads {
        let view = TrackpadPads()
        view.onPad = onPad
        return view
    }

    func updateNSView(_ view: TrackpadPads, context: Context) { view.onPad = onPad }
}

/// A finger landing on the trackpad plays the pad in that corner of it, and a click plays the pad clicked. Touches
/// only arrive while the drum machine has the keyboard and the pointer is over the pads.
final class TrackpadPads: NSView {
    var onPad: ((DrumPad) -> Void)?
    /// Fingers on the trackpad now
    private var touching = 0
    private var lastTouch: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        setAccessibilityElement(false)  // VoiceOver uses the pads underneath
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func touchesBegan(with event: NSEvent) {
        for touch in event.touches(matching: .began, in: self) {
            onPad?(DrumPad(at: touch.normalizedPosition))
        }
        counted(event)
    }

    override func touchesEnded(with event: NSEvent) { counted(event) }
    override func touchesCancelled(with event: NSEvent) { counted(event) }

    private func counted(_ event: NSEvent) {
        touching = event.touches(matching: .touching, in: self).count
        lastTouch = ProcessInfo.processInfo.systemUptime
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A mouse's click. A tap or press on the trackpad clicks too, which mustn't play the pad a second time.
    override func mouseDown(with event: NSEvent) {
        guard touching == 0, ProcessInfo.processInfo.systemUptime - lastTouch > 0.35,
              bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onPad?(DrumPad(at: CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)))
    }
}
