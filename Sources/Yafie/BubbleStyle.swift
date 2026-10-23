import AppKit
import SwiftUI

/// Bubble pop: saturated blue, white cards with thick ink outlines and hard offset shadows, chunky rounded type. The
/// menu and the tuner, drum machine and keyboard cleaning windows share it.
enum Bubble {
    static let blue = Color(red: 0.17, green: 0.37, blue: 0.94)
    static let ink = Color(red: 0.09, green: 0.12, blue: 0.24)
    static let tint = Color(red: 0.92, green: 0.95, blue: 1.0)
    static let hover = Color(red: 0.85, green: 0.90, blue: 1.0)
    static let yellow = Color(red: 0.98, green: 0.85, blue: 0.27)
    static let green = Color(red: 0.32, green: 0.79, blue: 0.43)
    /// For green text on white, which the pill green is too light for
    static let deepGreen = Color(red: 0.11, green: 0.56, blue: 0.25)
    static let orange = Color(red: 0.97, green: 0.53, blue: 0.22)
    static let red = Color(red: 0.91, green: 0.25, blue: 0.25)
    static let outline: CGFloat = 2
    static let radius: CGFloat = 10

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }
    static func body(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
}

extension View {
    /// A hairline above a card's row. The card's outline covers the first one's.
    func rowDivider() -> some View {
        overlay(alignment: .top) { Rectangle().fill(Bubble.ink.opacity(0.12)).frame(height: 1) }
    }

    /// A white card with an ink outline, sitting on a hard shadow
    func bubbleCard(fill: Color = .white, radius: CGFloat = Bubble.radius, lift: CGFloat = 3) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return clipShape(shape)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Bubble.ink, lineWidth: Bubble.outline))
            .background(shape.fill(Bubble.ink).offset(x: lift * 0.6, y: lift))
    }
}

extension NSPanel {
    /// Blue to the edges, under a see-through title bar that keeps the close button. Light, so the system controls
    /// on its white cards don't turn dark in Dark Mode.
    func useBubbleChrome() {
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = NSColor(Bubble.blue)
        appearance = NSAppearance(named: .aqua)
    }
}

/// A window's name in chunky white type, beside an outlined chip with its symbol
struct BubbleHeader: View {
    let title: String
    let symbol: String
    let chip: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Bubble.ink)
                .frame(width: 26, height: 26)
                .bubbleCard(fill: chip, radius: 7, lift: 2)
                .accessibilityHidden(true)
            Text(title)
                .font(Bubble.display(20))
                .foregroundStyle(.white)
                .shadow(color: Bubble.ink, radius: 0, x: 1.5, y: 2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
    }
}

/// A chunky pill that presses down into its shadow
struct BubbleButtonStyle: ButtonStyle {
    var fill: Color = .white
    var height: CGFloat = 26
    var fontSize: CGFloat = 12.5

    func makeBody(configuration: Configuration) -> some View {
        BubbleButtonBody(configuration: configuration, fill: fill, height: height, fontSize: fontSize)
    }
}

private struct BubbleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    let height: CGFloat
    let fontSize: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let lift: CGFloat = configuration.isPressed ? 0 : 2.5
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(Bubble.body(fontSize))
            .foregroundStyle(Bubble.ink)
            .padding(.horizontal, 9)
            .frame(minHeight: height)
            .background(shape.fill(configuration.isPressed ? fill.opacity(0.85) : fill))
            .overlay(shape.strokeBorder(Bubble.ink, lineWidth: Bubble.outline))
            .offset(x: 2.5 * 0.6 - lift * 0.6, y: 2.5 - lift)
            .background(shape.fill(Bubble.ink).offset(x: 1.5, y: 2.5))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
    }
}

/// A Toggle as a pill that turns green with a check when on, like the battle plan app's Going button
struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
                configuration.label
                    .lineLimit(1)
            }
        }
        .buttonStyle(BubbleButtonStyle(fill: configuration.isOn ? Bubble.green : .white, height: 24, fontSize: 12))
        .accessibilityValue(configuration.isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A switch like the battle plan app's: an outlined track with a square knob that shows a check when on
struct BubbleSwitch: View {
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let track = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let knob = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack(alignment: isOn ? .trailing : .leading) {
            track.fill(isOn ? Bubble.blue : Color.white)
            knob.fill(isOn ? Color.white : Bubble.ink.opacity(0.55))
                .overlay(knob.strokeBorder(Bubble.ink.opacity(isOn ? 0 : 0.6), lineWidth: 1))
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Bubble.blue)
                        .opacity(isOn ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .padding(3)
        }
        .frame(width: 40, height: 22)
        .overlay(track.strokeBorder(Bubble.ink, lineWidth: Bubble.outline))
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOn)
    }
}
