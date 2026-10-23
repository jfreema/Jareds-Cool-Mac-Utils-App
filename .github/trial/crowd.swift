// Fills the menu bar with numbered icons, about enough for a short menu bar but not a long one
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)  // the count reaches the file at once
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let width = NSScreen.main?.frame.width ?? 1440
let count = max(8, Int((width - 520) / 34))
var items: [NSStatusItem] = []
for number in 1...count {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let name = String(format: "%02d", number)
    item.autosaveName = "Crowd\(name)"  // the window's name, for the probe to find
    item.button?.title = name
    let menu = NSMenu()
    menu.addItem(withTitle: "Icon \(name)", action: nil, keyEquivalent: "")
    item.menu = menu
    items.append(item)
}
print("crowd: \(count) icons on a \(Int(width)) pt wide screen")
app.run()
