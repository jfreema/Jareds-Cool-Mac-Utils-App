// What the menu bar looks like to the window server, and a pointer and keyboard to poke it with
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "list"

func windows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
}

func bounds(_ window: [String: Any]) -> CGRect {
    CGRect(dictionaryRepresentation: window[kCGWindowBounds as String] as! CFDictionary) ?? .zero
}

switch command {
case "list":
    print("=== \(arguments.dropFirst().joined(separator: " "))")
    let front = NSWorkspace.shared.frontmostApplication
    print("front: \(front?.localizedName ?? "none"), policy \(front?.activationPolicy.rawValue ?? -1), "
          + "menu bar: \(NSWorkspace.shared.menuBarOwningApplication?.localizedName ?? "none")")
    print("trusted: \(AXIsProcessTrusted()), screen capture: \(CGPreflightScreenCaptureAccess())")
    for screen in NSScreen.screens {
        print("screen \(screen.frame) visible \(screen.visibleFrame) safe top \(screen.safeAreaInsets.top)")
    }
    print("pointer \(NSEvent.mouseLocation)")
    var shown = 0
    var hidden = 0
    for window in windows() {
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        guard [24, 25, 100, 101].contains(layer) else { continue }
        let frame = bounds(window)
        let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
        let name = window[kCGWindowName as String] as? String ?? ""
        let onScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
        if layer == 25 { if onScreen { shown += 1 } else { hidden += 1 } }
        print("  layer \(layer) #\(window[kCGWindowNumber as String] ?? 0) \(owner) '\(name)' on \(onScreen) "
              + "x \(Int(frame.minX)) y \(Int(frame.minY)) w \(Int(frame.width)) h \(Int(frame.height))")
    }
    print("status windows on screen \(shown), off \(hidden)")
case "sum":
    // One line: who's in front, whose menu bar it is, how many icons show, menus open, and the arrow
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
    let owner = NSWorkspace.shared.menuBarOwningApplication?.localizedName ?? "none"
    var shown = 0
    var hidden = 0
    var menus = 0
    var arrow = "no arrow"
    var crowd: [String] = []
    for window in windows() {
        let layer = window[kCGWindowLayer as String] as? Int ?? 0
        let frame = bounds(window)
        let name = window[kCGWindowName as String] as? String ?? ""
        let onScreen = window[kCGWindowIsOnscreen as String] as? Bool ?? false
        if layer == 25, frame.height <= 40 { if onScreen { shown += 1 } else { hidden += 1 } }
        if [100, 101].contains(layer), onScreen { menus += 1 }
        if layer == 25, frame.height > 40, onScreen { menus += 1 }
        if name == "HiddenIconsArrow" { arrow = "arrow \(onScreen ? "shown" : "HIDDEN") at x \(Int(frame.minX))" }
        if name.hasPrefix("Crowd"), onScreen { crowd.append(String(name.dropFirst(5))) }
    }
    let point = NSEvent.mouseLocation
    print("\(arguments.dropFirst().joined(separator: " ")): front \(front), menu bar \(owner), icons shown \(shown) "
          + "hidden \(hidden), crowd shown [\(crowd.sorted().joined(separator: " "))], menus open \(menus), \(arrow), "
          + "pointer \(Int(point.x)),\(Int(point.y))")
case "find":
    // The center of the named status item's window, in the window server's coordinates
    let name = arguments[1]
    if let window = windows().first(where: { ($0[kCGWindowName as String] as? String) == name }) {
        let frame = bounds(window)
        print("\(Int(frame.midX)) \(Int(frame.midY))")
    }
case "warp":
    CGWarpMouseCursorPosition(CGPoint(x: Double(arguments[1])!, y: Double(arguments[2])!))
case "click":
    let point = CGPoint(x: Double(arguments[1])!, y: Double(arguments[2])!)
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(100_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
case "key":
    // A key, with control and option held if asked: key 4 control option
    let code = CGKeyCode(arguments[1])!
    let modifiers: [(String, CGKeyCode, CGEventFlags)] = [("control", 59, .maskControl), ("option", 58, .maskAlternate)]
    let held = modifiers.filter { arguments.dropFirst(2).contains($0.0) }
    let flags = held.reduce(into: CGEventFlags()) { $0.insert($1.2) }
    let source = CGEventSource(stateID: .hidSystemState)
    func post(_ key: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
    var current = CGEventFlags()
    for (_, key, flag) in held {
        current.insert(flag)
        post(key, true, current)
    }
    post(code, true, flags)
    post(code, false, flags)
    for (_, key, flag) in held.reversed() {
        current.remove(flag)
        post(key, false, current)
    }
default:
    print("unknown command \(command)")
}
